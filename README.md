# kagent-flux-lab

End-to-end GitOps lab: **kind/OrbStack** → **Flux CD** → **Sealed Secrets** →
**cert-manager + trust-manager** → **MetalLB** → **Gateway API + agentgateway**
→ **kagent** → **Anthropic Claude / Ollama**. Everything HTTPS-only through a
single `agentgateway` ingress.

Lab progression: infrastructure bootstrapping (Lab 1) → RAG vector search
(Lab 2) → custom MCP server with layered defences (Lab 3) → custom A2A agent
with Sampling and Elicitation bridges (Lab 4 #1) → MCP governance dashboard (Lab
4 #3). Everything declarative in git, reconciled by Flux.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  kind cluster (2 nodes on OrbStack: 1 control-plane + 1 worker)             │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Flux CD ◄──── git push ──── GitHub repo                            │    │
│  │                                                                     │    │
│  │  Infrastructure                                                     │    │
│  │    sealed-secrets · metallb · gateway-api CRDs                      │    │
│  │    cert-manager + trust-manager (lab-ca, wildcard cert, Bundle)     │    │
│  │    agentgateway (LLM proxy + Gateway API controller)                │    │
│  │    kagent (agent framework)                                         │    │
│  │                                                                     │    │
│  │  Lab 2 — RAG                                                        │    │
│  │    qdrant (vector DB, 2 GiB PVC)                                    │    │
│  │    qdrant-embeddings Job (doc2vec, nomic-embed-text 768d)           │    │
│  │    querydoc-mcp (read-only MCP server)                              │    │
│  │    doc-agent (kagent Agent, RAG via querydoc-mcp)                   │    │
│  │                                                                     │    │
│  │  Lab 3 — doc-writer-mcp                                             │    │
│  │    doc-writer-mcp (write MCP server, L0-L5 layered defence)        │    │
│  │    writer-agent (kagent Agent, ingest via doc-writer-mcp)           │    │
│  │                                                                     │    │
│  │  Lab 4 #1 — ingest-orchestrator (A2A agent)                        │    │
│  │    Go service, A2A spec, Claude tool-use loop via agentgateway      │    │
│  │    Sampling bridge + Elicitation bridge (SSE + PendingRegistry)     │    │
│  │                                                                     │    │
│  │  Lab 4 #3 — mcp-governance                                          │    │
│  │    OWASP MCP security scoring dashboard                             │    │
│  │    AI analysis via Ollama qwen2.5:14b on OrbStack host             │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  Single MetalLB IP 192.168.97.200 → agentgateway-proxy (HTTPS :443)        │
│                                                                              │
│  https://kagent.ash.ph.lab          → kagent UI                             │
│  https://flux.ash.ph.lab            → Headlamp + Flux plugin                │
│  https://qdrant.ash.ph.lab          → Qdrant dashboard                      │
│  https://querydoc.ash.ph.lab/mcp    → querydoc MCP (read)                   │
│  https://doc-writer.ash.ph.lab/mcp  → doc-writer MCP (write)                │
│  https://ingest.ash.ph.lab          → ingest-orchestrator A2A               │
│  https://mcpg.ash.ph.lab            → mcp-governance dashboard              │
│  https://agentgateway.ash.ph.lab    → agentgateway admin UI                 │
└──────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
        api.anthropic.com (TLS) | Mac host Ollama :11434 (plain HTTP)
        both via agentgateway with OpenAI→Anthropic translation
```

### Agent interaction map

```
                      agentgateway-proxy (in-cluster HTTPS)
                              │
              ┌───────────────┼───────────────────┐
              │               │                   │
         kagent agents   ingest-orchestrator   doc-writer-mcp
         (doc-agent,     (A2A, Go)             (MCP server, Go)
          writer-agent)       │                       │
              │               │ MCP Streamable HTTP   │ Elicitation
              │ RemoteMCPServer│ (doc-writer.ash.ph.lab/mcp)  │
              └───────►────────┴──────────────────────┘
              │
              │ ModelConfig claude-via-gateway
              ▼
         agentgateway ──────────────────────► api.anthropic.com
         AgentgatewayBackend: anthropic
```

## Lab Progression

### Lab 1 — Flux Bootstrap + Infrastructure

What it establishes: the cluster itself, all shared components, and the single
HTTPS ingress that every subsequent lab rides on.

**Components:**

- `kind/cluster.yaml` — 2-node OrbStack kind cluster (control-plane + worker)
- **sealed-secrets** — RSA-encrypted secrets committed to git;
  auto-backup/restore of RSA keypair survives cluster recreate
- **MetalLB** — L2 pool `192.168.97.200-250`; single IP for all traffic
- **cert-manager + trust-manager** — self-signed `lab-ca` ClusterIssuer,
  `*.ash.ph.lab` wildcard cert, trust-manager Bundle distributes CA cert to pods
  via ConfigMap + `SSL_CERT_FILE`
- **Gateway API CRDs** v1.2.x experimental channel
- **agentgateway** — single `Gateway` resource `agentgateway-proxy` plays both
  ingress (HTTPRoute SNI routing) and LLM proxy (AgentgatewayBackend for
  Anthropic and Ollama) roles
- **kagent** — agent framework with `ModelConfig` pointing at claude-via-gateway
  (OpenAI SDK body, gateway translates to Anthropic native)
- **Headlamp** — Kubernetes dashboard with Flux plugin, view-only RBAC

**Why agentgateway as the single ingress:** Traditional setup would need
`ingress-nginx` or Traefik for HTTP traffic, plus a separate LLM proxy (LiteLLM,
OpenRouter) for model routing. agentgateway collapses both into one controller.
Trade-off: less flexibility per-layer, faster for a lab.

**Why `provider: OpenAI` in ModelConfigs:** agentgateway has a `tool_choice`
parser bug for native Anthropic bodies. kagent ADK emits OpenAI format → gateway
translates → Anthropic native. Intentional workaround; revert once upstream
fixes the bug.

### Lab 2 — Qdrant + querydoc-mcp + doc-agent

What it adds: a vector database, a Flux-managed embedding job, a read-only MCP
server, and a self-referential RAG agent.

**Components:**

- **Qdrant** — vector DB (HelmRelease, 2 GiB PVC), collections `kagent-flux-lab`
  (docs) and `kagent-flux-lab-code` (code)
- **qdrant-embeddings Job** — Flux-managed `batch/v1 Job`, initContainer
  git-clones this repo, main container runs `doc2vec` writer with Ollama
  `nomic-embed-text` (768d); runs once on deploy, re-triggered by image digest
  bump
- **querydoc-mcp** — read-only MCP server exposing three tools:
  `query_documentation`, `query_code`, `get_chunks`; backed by the two Qdrant
  collections; exposed at `https://querydoc.ash.ph.lab/mcp`
- **doc-agent** — kagent `Agent` (CRD) that uses querydoc-mcp via
  `RemoteMCPServer` to answer questions about this repository's own
  documentation and code; "self-referential RAG" because the repo docs are what
  populated Qdrant

**Why Flux-managed Job instead of host-side script:** The embedding run is
reproducible, git-driven, and observable in the Flux dashboard. No manual step
after cluster recreate.

### Lab 3 — doc-writer-mcp + writer-agent

What it adds: a write-path MCP server with a layered security/quality pipeline,
and a kagent agent that consumes it.

**Components:**

- **doc-writer-mcp** — custom Go MCP server (repo: `pylyp-gh/doc-writer-mcp`),
  deployed as `kagent.dev/v1alpha1 MCPServer` CRD, exposed at
  `https://doc-writer.ash.ph.lab/mcp`
- **writer-agent** — kagent `Agent` (CRD) consuming `doc-writer-mcp` via
  `RemoteMCPServer`, model `claude-via-gateway`

**doc-writer-mcp layered defence (L0-L5):**

```
Input text
  │
  L0  Structural:   empty check · UTF-8 validity · length bounds (50–32768 chars)
  │                 URL format check for sourceUrl
  L1  Lexical:      token diversity (≥3 unique) · repeat ratio (≤0.60) ·
  │                 language gate (≤5% non-Latin/Cyrillic letters) ·
  │                 injection regex (XSS tags, "ignore previous instructions",
  │                 "you are now", "system prompt:", etc.) ·
  │                 placeholder blacklist (lorem ipsum, foo bar baz...)
  L2  Hash dedup:   SHA-256 over trimmed text → skip embed if exact duplicate
  │                 already exists in Qdrant
  [embed via Ollama nomic-embed-text 768d]
  L4  Cosine dedup: similarity ≥ 0.95 vs existing vectors →
  │                 Elicitation: ask caller {new_version|replace|decline|add_anyway}
  L5  LLM gate:     Sampling round 1 — ACCEPT/REJECT verdict (≤100 tokens)
  │                 Sampling round 2 — metadata extraction: title, tags[], summary
  │                 (≤500 tokens)
  │
  Qdrant upsert (collection "doc-writer", 768d Cosine)
```

**Elicitation in Lab 3:** Two triggers:

1. **Collection bootstrap** — Qdrant collection missing: `{create: boolean}`
   schema. writer-agent (kagent runtime) does not declare the elicitation
   capability; the tool returns a hard error, forcing operator awareness.
2. **Cosine duplicate** — similarity ≥ 0.95: `{choice: enum}` schema. Same hard
   error for writer-agent; this is intentional — Lab 4 adds the bridge.

**Sampling in Lab 3:** Two-step: verdict first (cheap, ≤100 tokens), then
metadata only if accepted (≤500 tokens). Controlled by `ENABLE_SAMPLING=true`
env; operator can flip to false for bulk-ingest scenarios where double LLM
round-trip is unacceptable.

### Lab 4 #1 — ingest-orchestrator (A2A agent)

What it adds: an independent Go service that speaks the A2A protocol, drives
doc-writer-mcp as a full MCP client (Sampling + Elicitation), and surfaces
interactive elicitation prompts back to callers over HTTP SSE without WebSocket.

**Component:** `ingest-orchestrator` — custom Go service (repo:
`pylyp-gh/ingest-orchestrator`), deployed as a plain `Deployment` in namespace
`ingest-orchestrator`, exposed at `https://ingest.ash.ph.lab`.

Not a kagent `Agent` CRD — this is intentional. kagent's agent runtime does not
declare `sampling` or `elicitation` capabilities; by building outside kagent the
service gets full MCP protocol capability parity with no framework constraints.

**Four implementation phases (all shipped):**

**Phase 1 — HTTP server + Agent Card**

- `GET /.well-known/agent-card.json` — A2A agent discovery endpoint
- `GET /healthz` — readiness/liveness probe
- `POST /messages` — synchronous A2A message handler (no streaming, no LLM yet)

**Phase 2 — Claude tool-use loop via gateway**

- OpenAI SDK (`openai-go`) → `OPENAI_BASE_URL=agentgateway-proxy/v1/`; gateway
  translates to Anthropic native; stub API key satisfies SDK auth, real key
  stays in gateway Secret
- Agentic loop: `tools = [add_document]`, Claude calls the tool, orchestrator
  calls `mc.CallTool`, returns result, loop continues until
  `stop_reason=end_turn`

**Phase 3 — Sampling bridge**

- doc-writer-mcp fires `sampling/createMessage` for L5 LLM gate
- `CreateMessageHandler` in orchestrator translates the MCP CreateMessage
  request to an OpenAI ChatCompletion call against agentgateway, returns the
  completion text back to the MCP server as a sampling result

**Phase 4 — Elicitation bridge via A2A SSE**

```
POST /messages:stream               (caller opens SSE stream)
     │
     ├─► emit {status:"WORKING"}
     ├─► per-request mcp.NewClient  (one MCP session per HTTP request)
     │     ElicitationHandler closure captures THIS request's SSE stream
     ├─► Loop(claude) → CallTool("add_document", ...)
     │
     │   doc-writer-mcp fires elicitation/create (cosine dup found)
     │
     ├─► ElicitationHandler invoked by SDK dispatcher goroutine
     │     pending.Register() → correlation_id, channel
     │     stream.SendEvent({status:"input-required", correlation_id, schema})
     │     select { case res := <-ch }  ← BLOCKS (2-minute timeout)
     │
     │   (caller reads SSE event, POSTs to /messages:respond)
     │
POST /messages:respond
     │   pending.Deliver(correlation_id, {action, content})
     │   → writes to buffered channel → unblocks ElicitationHandler
     │
     ├─► MCP server resumes, upserts to Qdrant
     └─► emit {status:"COMPLETED", result:{...}}
```

**Key design decisions:**

- **Two HTTP endpoints, not WebSocket** — `POST /messages:stream` (SSE out) +
  `POST /messages:respond` (human response in) correlated by UUID. Any HTTP
  client participates: `curl` can chunk-read SSE and fire a second POST.
- **Per-request `mcp.NewClient`** — the Go SDK dispatcher runs in a background
  goroutine keyed to the transport-level context (not the caller's `CallTool`
  ctx). Passing request-scoped state through `context.WithValue` silently does
  nothing. Fix: each `/messages:stream` request creates its own MCP session with
  a closure capturing that request's SSE stream. Cost: ~100-300ms for MCP
  `initialize` handshake per request — acceptable for interactive ingest.
- **`PendingRegistry` as `sync.Map`** keyed on UUIDv4 correlation IDs — multiple
  concurrent streams share one registry; channels are buffered (size 1) so
  `Deliver` never blocks even if it races with a timeout cleanup.
- **Policy handler for sync `/messages`** — no peer SSE stream available;
  bootstrap elicitation auto-accepted (creating an empty collection carries no
  content risk), duplicate elicitation auto-declined (silent overwrite =
  potential data loss).

### Lab 4 #3 — mcp-governance

What it adds: OWASP MCP security scoring over all in-cluster MCP servers, with
AI reasoning via a local Ollama model.

**Component:** `mcp-governance` — forked from
`techwithhuz/mcp-security-governance`, published to `pylyp-gh`, deployed at
chart version `0.22.3` via HelmRelease. Dashboard at `https://mcpg.ash.ph.lab`.

**Policy (`kagent-flux-lab-policy`):** All eight OWASP MCP Tier 1 controls
enabled (`requireAgentGateway`, `requireTLS`, `requireHardenedDeployment`,
`requireJWTAuth`, `requireRBAC`, `requireCORS`, `requireRateLimit`,
`requirePromptGuard`). Current lab satisfies the first three; the other five are
tracked as production gaps — intentionally visible in the score.

**AI scoring:** `aiAgent.provider: ollama`, `model: qwen2.5:14b`, endpoint
`http://host.docker.internal:11434`. Adds reasoning and actionable suggestions
on top of the algorithmic score. OrbStack host DNS alias `host.docker.internal`
resolves to the VM gateway IP from inside kind containers.

**CRD bug workaround:** Chart's `crds/` directory has a duplicate YAML key in
`mcpgovernancepolicies.yaml` (upstream issue
`techwithhuz/mcp-security-governance#27`). Helm does not apply postRenderers to
the `crds/` directory, so the bug cannot be patched at deploy time. Fix:
`crds: Skip` in HelmRelease + three fixed CRD manifests applied as standalone
resources in the same Kustomization (`crd-mcpgovernancepolicy.yaml`,
`crd-governanceevaluation.yaml`, `crd-agentregistry.yaml`).

## Networking & TLS

**One Gateway API `Gateway` for the whole stack** — `agentgateway-proxy`
(`gateway.networking.k8s.io/v1`) declares a single HTTPS listener on port 443.
The `agentgateway` controller materialises that Gateway into a Deployment +
`LoadBalancer` Service of the same name, and MetalLB assigns the Service the
single IP `192.168.97.200`. All HTTP(S) traffic (browser → UI, in-cluster pod →
model) hits that listener and is fanned out by `HTTPRoute` hostname/path
matching. It is a **production-inspired pattern** — `agentgateway` plays the
role of ingress + LLM router at the same time.

**HTTPS-only.** Browsers require Secure Context for the Web Crypto API
(`crypto.randomUUID()` in the Next.js UI). The HTTP listener was removed
entirely. Cert signed by self-signed CA (`lab-ca` ClusterIssuer); accept the
browser warning once, or import the CA into Keychain.

**In-cluster TLS trust.** Pods reach the model via
`https://agentgateway-proxy.agentgateway-system.svc.cluster.local`. The cert has
extended SANs covering all in-cluster Service DNS variants. Pods read lab-ca via
**trust-manager Bundle** → ConfigMap in each namespace → mounted →
`SSL_CERT_FILE`.

**DNS on home router** — single wildcard entry `*.ash.ph.lab` → `192.168.97.200`
covers all current and future subdomains for all LAN devices.

## Quick start

```bash
cp .envrc.example .envrc
# fill in ANTHROPIC_API_KEY, GITHUB_USER
direnv allow .

make prereqs          # check tools, gh auth, env vars
make cluster-up       # kind + MetalLB-ready network (auto-restores sealed-secrets RSA if backup exists)
make flux-bootstrap   # create GitHub repo + Flux GitOps
# from here — everything via git push to the Flux repo

# IF first time (no RSA backup at ~/.sealed-secrets-keys/<cluster>.yaml):
#   make seal             # re-seal anthropic-secret with the current cluster's RSA
#   git add clusters/kind-lab/apps/base/sealed/anthropic.yaml && git commit && git push
# Otherwise Flux will sync the existing SealedSecret which the cluster can't decrypt.

# after bootstrap (~5 min reconcile):
# 1. add wildcard DNS entry: *.ash.ph.lab → 192.168.97.200 (MetalLB IP)
# 2. (optional) add lab-ca cert to Keychain → no browser warning
# 3. Headlamp token (7-day):
#    kubectl -n headlamp create token headlamp --duration=168h | pbcopy
```

**GHCR visibility note (Lab 3 + Lab 4 #1):** images
`ghcr.io/pylyp-gh/doc-writer-mcp` and `ghcr.io/pylyp-gh/ingest-orchestrator`
must be set to **public** in GitHub package settings after the first push. GHCR
defaults to private for new packages; kind nodes pull without `imagePullSecret`
so private images will fail with `ImagePullBackOff`. Navigate to the package
settings page once per image.

## Make targets

| target                | what it does                                       |
| --------------------- | -------------------------------------------------- |
| `make prereqs`        | check tools, gh auth, env vars                     |
| `make cluster-up`     | create kind cluster on OrbStack subnet             |
| `make flux-bootstrap` | gh repo create + flux bootstrap github             |
| `make seal`           | kubeseal helper for secrets (stdin → SealedSecret) |
| `make status`         | nodes + flux state                                 |
| `make cluster-down`   | tear down everything                               |

## Repository structure

```
.
├── scripts/                                  # bash entry points (idempotent)
├── kind/cluster.yaml                         # kind cluster spec
└── clusters/kind-lab/                        # GitOps tree
    ├── flux-system/                          # auto-generated by flux bootstrap
    ├── infrastructure.yaml                   # Flux Kustomizations: infra-controllers, infra-configs
    ├── apps.yaml                             # Flux Kustomizations: apps-base, kagent-stubs,
    │                                         #   *-controller, *-routes, *-config
    ├── infrastructure/
    │   ├── controllers/                      # cert-manager, gateway-api CRDs, sealed-secrets, metallb
    │   └── configs/                          # cert-manager issuers, metallb pool, trust-bundle
    └── apps/
        ├── base/                             # namespaces, anthropic SealedSecret
        ├── agentgateway/                     # controller HelmRelease + all HTTPRoutes + Gateway
        ├── headlamp/                         # Headlamp UI + Flux plugin
        ├── qdrant/                           # Qdrant vector DB HelmRelease
        ├── qdrant-embeddings/                # doc2vec Job (Lab 2)
        ├── kagent/
        │   ├── controller/                   # kagent HelmRelease
        │   ├── stubs/                        # openai-stub Secret (applied early)
        │   └── config/                       # ModelConfigs, agents, MCP registrations
        │       ├── doc-agent.yaml            # Lab 2 — RAG agent
        │       ├── querydoc-mcp.yaml         # Lab 2 — RemoteMCPServer querydoc
        │       ├── writer-agent.yaml         # Lab 3 — ingest agent
        │       ├── doc-writer-mcp-remote.yaml# Lab 3 — RemoteMCPServer doc-writer
        │       └── ...                       # trust patches, test agents
        ├── doc-writer/                       # Lab 3 — doc-writer-mcp MCPServer CRD
        ├── ingest-orchestrator/              # Lab 4 #1 — A2A agent Deployment + Service
        └── mcp-governance/                   # Lab 4 #3 — governance HelmRelease + fixed CRDs
```

## Multi-cluster / test environment setup

To run a **second kind cluster in parallel** (e.g., for E2E testing from scratch
without touching production state) set **three** env vars before make:

```bash
export CLUSTER_NAME=kind-lab-test       # new kind cluster name (different docker container)
export GITHUB_BRANCH=test-e2e            # separate git branch for test config tweaks
export FLUX_PATH=clusters/kind-lab       # GitOps tree path (same as prod!)
```

`CLUSTER_NAME` and `FLUX_PATH` are **separate concepts** — runtime identifier vs
storage identity in git. The bootstrap script defaults to `clusters/kind-lab`,
not to `clusters/${CLUSTER_NAME}`. For multi-cluster setup this lets you reuse
the same GitOps tree via branch tweaks (e.g., `test-e2e` branch has a
non-overlapping MetalLB IP slice and a different `apiServerPort`). This is the
GitOps **branch-per-env** pattern, as opposed to path-per-env where git has a
separate directory per cluster.

## UI access

All UIs share `192.168.97.200` via hostname-based routing. HTTPS terminates at
the gateway with the `*.ash.ph.lab` wildcard cert.

| URL                                 | Service                  | Auth                                |
| ----------------------------------- | ------------------------ | ----------------------------------- |
| `https://kagent.ash.ph.lab`         | kagent agent management  | none                                |
| `https://flux.ash.ph.lab`           | Headlamp + Flux plugin   | 7-day token (see below)             |
| `https://qdrant.ash.ph.lab`         | Qdrant dashboard         | none                                |
| `https://agentgateway.ash.ph.lab`   | agentgateway xDS admin   | none (intentional lab anti-pattern) |
| `https://mcpg.ash.ph.lab`           | mcp-governance dashboard | none                                |
| `https://querydoc.ash.ph.lab/mcp`   | querydoc MCP endpoint    | none (programmatic)                 |
| `https://doc-writer.ash.ph.lab/mcp` | doc-writer MCP endpoint  | none (programmatic)                 |
| `https://ingest.ash.ph.lab`         | ingest-orchestrator A2A  | none (programmatic)                 |

**Headlamp token** (Headlamp 0.40+ removed anonymous access):

```sh
kubectl -n headlamp create token headlamp --duration=168h | pbcopy
```

`sessionTTL: 604800` in the chart values matches the token duration — one paste
per week. RBAC is bound to the built-in `view` ClusterRole (read-only; Secrets,
kagent CRDs, and Gateway API resources deliberately excluded from `view`
aggregation).

## Key learnings & gotchas

### MCP Go SDK — async dispatcher breaks `context.WithValue`

**Symptom:** `context.WithValue` plumbed into `mc.CallTool()` is invisible to
`ElicitationHandler` and `SamplingHandler`. The handlers always see a nil value.

**Root cause:** The SDK dispatcher runs in a background goroutine started at
`ClientSession` establishment. Server-initiated callbacks
(`sampling/createMessage`, `elicitation/create`) are routed to handlers using
the transport-level context (the `ClientSession` lifetime), not the context
passed to `CallTool()`. Handlers are also fixed at session creation time — there
is no `SetHandler` API.

**Fix:** Per-request `mcp.NewClient`. Each streaming request constructs a fresh
MCP session with an `ElicitationHandler` closure that captures the
request-scoped SSE stream at construction time. Cost: one `initialize` handshake
(~100-300ms) per request, acceptable for interactive ingest.

Full analysis:
`/Volumes/crypta/_obsidian/ph+claude/60-Claude/learnings/2026-05-18-mcp-go-sdk-async-dispatcher-ctx-gotcha.md`

### MCP Elicitation via A2A SSE — the two-endpoint pattern

**Pattern:** `POST /messages:stream` opens SSE (server→client), handler blocks
on a channel inside the elicitation closure. `POST /messages:respond` delivers
the human response, writing to the buffered channel and unblocking the handler.
Correlated by UUIDv4 `correlation_id`. No WebSocket needed; `curl` can drive
both legs.

**Why not shared session + mutex:** `ElicitTimeout` is 2 minutes (waiting on
human input). A mutex serialises all concurrent callers behind that timeout — a
queue, not parallelism. Per-request session isolation eliminates the contention
entirely.

Full pattern with wire format:
`/Volumes/crypta/_obsidian/ph+claude/60-Claude/learnings/2026-05-18-mcp-elicitation-via-a2a-sse-bridge.md`

### agentgateway `tool_choice` parser bug

Native Anthropic bodies from kagent ADK trigger a parser bug in agentgateway.
Workaround: `provider: OpenAI` in ModelConfigs; gateway translates the OpenAI
body to Anthropic native on the way out. Track upstream for when
`provider: Anthropic` can be restored without breakage.

### Headlamp RBAC aggregation

`view` ClusterRole uses an aggregation rule — any ClusterRole tagged
`rbac.authorization.k8s.io/aggregate-to-view: "true"` is automatically included.
Flux CRDs and cert-manager ship such labels; kagent and Gateway API do not. To
expose kagent CRDs in Headlamp without a Helm upgrade, apply a thin ClusterRole
with the label:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-view
  labels:
    rbac.authorization.k8s.io/aggregate-to-view: "true"
rules:
  - apiGroups: ["kagent.dev"]
    resources: ["agents", "modelconfigs", "mcpservers", "toolservers"]
    verbs: ["get", "list", "watch"]
```

## Known limitations (lab-specific)

- **Self-signed CA** — browsers warn on first visit, accept once. Do not carry
  to production without a real CA (Let's Encrypt + ExternalDNS).
- **NetworkPolicy absent** — agent pods can reach anything in the cluster.
  Production needs zone separation via CNI policies.
- **Fake API keys in stub Secrets** — `kagent-openai` has
  `fake-not-validated-at-init`; real auth happens gateway-side. Anti-pattern if
  a pod ever bypasses the gateway.
- **GHCR package visibility** — `ghcr.io/pylyp-gh/*` packages must be manually
  set to public after first CI push. No imagePullSecret in kind nodes.
- **No observability stack** — no Prometheus, Grafana, Loki, or OTel Collector.
  See Roadmap.
- **Single-replica deployments without PodDisruptionBudget** — `kubectl drain`
  triggers downtime for all components.
- **Permanent `debug` logging in agentgateway** — full request bodies (with API
  keys, prompts) in stdout. Production should route logs via a collector with
  redaction before storage.
- **mcp-governance CRD bug (upstream #27)** — chart `crds/` cannot be patched by
  Helm postRenderers; fixed CRDs applied as standalone resources alongside the
  HelmRelease. Pending upstream fix.
- **ingest-orchestrator MCP `initialize` latency** — ~100-300ms per streaming
  request due to per-request MCP session. Acceptable for interactive ingest, but
  not for high-throughput bulk ingest.
- **DNS by hand on the router** — no ExternalDNS controller.
- **agentgateway admin UI exposed without auth** — xDS dump, route config,
  secret refs visible to anyone who resolves DNS. Fine for lab introspection;
  production needs OAuth2-proxy + OIDC or port-forward only.

## Pending work

- **Lab 4 #2** — not yet started (placeholder)
- **Supply-chain hardening** — GitHub Actions render + OCI push, cosign keyless
  signing, Flux `OCIRepository.spec.verify`, Kyverno `verifyImages` admission
  policy
- **Observability stack** — OTel Collector → Prometheus + Grafana; Vector log
  pipeline with API key redaction; `tracing.ash.ph.lab`
- **NetworkPolicy / Cilium zone separation** — agents egress only to
  `agentgateway-proxy`; proxy egress only to `api.anthropic.com` + host Ollama
- **OAuth2-proxy + OIDC** for agentgateway admin UI
- **ExternalDNS** replacing hand-maintained router DNS entries
- **Provider switch back to native Anthropic** in ModelConfigs once upstream
  `tool_choice` parser bug is fixed
- **Day 2 upgrade workflow** — explicit recipe: `crane digest` → update
  `ref.tag + ref.digest` → `git push` → `flux reconcile`

## Forks & dependencies

A few images consumed by this lab come from forks rather than upstream — see
[`FORKS.md`](FORKS.md) for per-fork rationale, upstream PR links, and the
convergence plan.
