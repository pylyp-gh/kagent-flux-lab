# kagent-flux-lab

End-to-end GitOps lab: **kind/OrbStack** → **Flux CD** → **Sealed Secrets** →
**cert-manager + trust-manager** → **MetalLB** → **Gateway API + agentgateway**
→ **kagent** → **Anthropic Claude / Ollama**. Everything HTTPS-only through a
single `agentgateway` ingress.

Goal — minimum manual work, everything via `make` + git push. All infra state
lives declaratively in a separate GitHub repo, reconciled by Flux.

## Topology

```
┌──────────────────────────────────────────────────────────────────┐
│  kind cluster (2 nodes on OrbStack: 1 control-plane + 1 worker) │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  Flux CD ◄──── git push ──── GitHub repo                  │   │
│  │     │                                                     │   │
│  │     ├─► sealed-secrets (RSA key auto-backup/restore)      │   │
│  │     ├─► metallb (L2 pool 192.168.97.200-250)              │   │
│  │     ├─► gateway-api CRDs (v1.5.0 experimental)            │   │
│  │     ├─► cert-manager + trust-manager                      │   │
│  │     │     └─► lab-ca self-signed Root CA                  │   │
│  │     │     └─► wildcard cert *.ash.ph.lab + in-cluster SANs │   │
│  │     │     └─► Bundle → ConfigMap in kagent + agentgateway │   │
│  │     ├─► agentgateway (LLM proxy + Gateway API impl)       │   │
│  │     │     └─► AgentgatewayBackend: anthropic + ollama     │   │
│  │     │     └─► HTTPS-only listener (HTTP removed)          │   │
│  │     │     └─► HTTPRoute: kagent-ui, agentgateway-ui,      │   │
│  │     │           anthropic, anthropic-completions, ollama  │   │
│  │     └─► kagent (agent framework)                          │   │
│  │           └─► 10 chart-managed agents → claude-via-gateway│   │
│  │           └─► 2 git-managed test agents (anthropic+ollama)│   │
│  │           └─► trust patches: SSL_CERT_FILE + lab-ca mount │   │
│  └───────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Single MetalLB IP 192.168.97.200 → Service agentgateway-proxy   │
│  ▼ TLS terminate ▼ HTTPRoute SNI/path routing                    │
│     • https://kagent.ash.ph.lab       → kagent-ui Service         │
│     • https://flux.ash.ph.lab         → headlamp Service          │
│     • https://qdrant.ash.ph.lab       → qdrant Service:6333       │
│     • https://querydoc.ash.ph.lab     → kagent-querydoc Service   │
│     • https://agentgateway.ash.ph.lab → agentgateway-proxy:15010  │
│     • https://...local/v1/messages   → AgentgatewayBackend       │
│     • https://...local/ollama/...    → Mac host Ollama (chat)    │
│     • https://...local/ollama-embed  → Mac host Ollama (embeds)  │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
       api.anthropic.com (TLS) │ Mac host Ollama 11434 (plain HTTP)
       both via agentgateway with translation/forwarding
```

## Networking & TLS

**One Gateway API `Gateway` for the whole stack** — `agentgateway-proxy`
(`gateway.networking.k8s.io/v1`) declares a single HTTPS listener on port 443.
The `agentgateway` controller materialises that Gateway into a Deployment +
`LoadBalancer` Service of the same name, and MetalLB assigns the Service the
single IP `192.168.97.200`. All HTTP(S) traffic (browser → UI, in-cluster pod →
model) hits that listener and is fanned out by `HTTPRoute` hostname/path
matching. It's a **production-inspired pattern** — `agentgateway` plays the role
of ingress + LLM router at the same time.

**HTTPS-only.** Browsers require Secure Context for the Web Crypto API
(`crypto.randomUUID()` in the Next.js UI). So the HTTP listener was removed
entirely — `http://` to port 80 just times out. Cert signed by self-signed CA
(`lab-ca` ClusterIssuer); the browser shows a warning once → accept.

**In-cluster TLS trust.** kagent agent pods reach the model via
`https://agentgateway-proxy.agentgateway-system.svc.cluster.local`. The cert has
extended SANs for in-cluster Service DNS (all variants from short hostname to
FQDN). Pods read lab-ca via **trust-manager Bundle** → ConfigMap in the `kagent`
ns → mounted into pod → `SSL_CERT_FILE` env. Python httpx sees the bundle, TLS
handshake succeeds.

**DNS on home router** — a single wildcard entry `*.ash.ph.lab` →
`192.168.97.200` (MetalLB IP) resolves every hostname under the zone (currently
`kagent`, `flux`, `qdrant`, `querydoc`, `agentgateway`; future `tracing`, etc.)
for all devices in the LAN. Per-host entries unnecessary.

## agentgateway as the single ingress

One Gateway resource `agentgateway-proxy` serves:

- **UI traffic** (HTTPRoute with `backendRef.kind=Service`) — kagent UI, gateway
  admin UI
- **LLM API traffic** (HTTPRoute with `backendRef.kind=AgentgatewayBackend`) —
  Anthropic Messages, Anthropic-flavored OpenAI completions, Ollama

Hostname-based routing splits UI from API:

- `*.ash.ph.lab` SNI → wildcard cert
- HTTPRoutes with explicit `hostnames:` claim their subdomain
- HTTPRoutes without `hostnames:` (anthropic, ollama) catch in-cluster requests
  via Service DNS

This **replaces a traditional ingress controller** (nginx-ingress, traefik) +
**LLM proxy layer** (LiteLLM, OpenRouter) with a single component. Trade-off —
less flexibility than separate layers, but faster for a lab.

## UI access

Three browser UIs share the same MetalLB IP via hostname-based routing. HTTPS
terminates at the gateway with the `*.ash.ph.lab` wildcard cert signed by
self-signed `lab-ca` (accept browser warning once, or import the CA into
Keychain for a clean trust experience).

### kagent UI — `https://kagent.ash.ph.lab`

Agent management dashboard: list / create / chat with Agents, view ModelConfigs,
MCP toolservers. **No authentication** (deliberate lab choice; production would
gate behind OAuth2-proxy + OIDC — see Roadmap).

### agentgateway admin UI — `https://agentgateway.ash.ph.lab`

Live xDS dump, route config, backend secret refs (read-only debugging endpoint
via the socat sidecar on port 15010). **No authentication** — intentional
anti-pattern for lab introspection; do not replicate in prod.

### Headlamp + Flux plugin — `https://flux.ash.ph.lab`

Kubernetes dashboard with Flux sidebar (GitRepositories, Kustomizations,
HelmReleases, OCIRepositories visible). **Token required** — Headlamp 0.40+
removed the anonymous-access option as a security hardening; there is no
`--no-auth` flag.

Generate a 7-day token bound to the `headlamp` ServiceAccount and paste into the
login screen:

```sh
kubectl -n headlamp create token headlamp --duration=168h | pbcopy
```

`sessionTTL: 604800` (chart value) matches the token duration — one paste per
week.

**Read-only RBAC.** The ServiceAccount binds to the **built-in `view`
ClusterRole**, not `cluster-admin` (chart default overridden via
`clusterRoleBinding.clusterRoleName: view`). `view` uses an _aggregation rule_:
it auto-includes any ClusterRole tagged
`rbac.authorization.k8s.io/aggregate-to-view=true`. In our cluster that covers
Flux CRDs (`flux-view-flux-system`) and cert-manager (`cert-manager-view`) out
of the box.

**Deliberately not visible without extra RBAC:**

- `Secrets` — built-in `view` excludes them by design (raw API keys leak risk;
  clipboard equals exfiltration in a "read-only" dashboard).
- `kagent.dev/*` (Agent, ModelConfig, MCPServer) — kagent does not ship an
  aggregate-to-view ClusterRole.
- `gateway.networking.k8s.io/*` (HTTPRoute, Gateway) — Gateway API CRDs are not
  aggregated either.

To make a specific CRD visible, ship a custom ClusterRole with the aggregation
label:

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

Apply once → `view` re-aggregates at runtime → Headlamp's existing token gains
visibility on the new objects with no Helm upgrade or restart.

### Qdrant dashboard — `https://qdrant.ash.ph.lab`

Vector DB browser — inspect collections (`kagent-flux-lab`,
`kagent-flux-lab-code`), view individual points + metadata + vector previews.
Read-only by browser (no auth — REST API also accessible at the same hostname,
e.g., `https://qdrant.ash.ph.lab/collections`).

### querydoc MCP server — `https://querydoc.ash.ph.lab/mcp`

Streamable HTTP MCP endpoint used by the `doc-agent` (and any future kagent
Agent that registers querydoc as a tool source). Exposes three tools:
`query_documentation`, `query_code`, `get_chunks`. Backed by the two Qdrant
collections populated by the embedding Job. Not a browser UI — programmatic
endpoint for MCP clients, but reachable via the same gateway pattern.

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
# 1. add a single wildcard DNS entry on router: *.ash.ph.lab → MetalLB IP (192.168.97.200)
# 2. (optional) add lab-ca cert to Keychain trust → no browser warning
# 3. for Headlamp UI: generate 7-day token →
#    kubectl -n headlamp create token headlamp --duration=168h | pbcopy
```

## Multi-cluster / test environment setup

To run a **second kind cluster in parallel** (e.g., for E2E testing from scratch
without touching production state) set **three** env vars before make:

```bash
export CLUSTER_NAME=kind-lab-test       # new kind cluster name (different docker container)
export GITHUB_BRANCH=test-e2e            # separate git branch for test config tweaks
export FLUX_PATH=clusters/kind-lab       # GitOps tree path (same as prod!)
```

**Why FLUX_PATH explicit:** `CLUSTER_NAME` and `FLUX_PATH` are **separate
concepts**:

- `CLUSTER_NAME` — runtime identifier (kind container name, kubectl context).
- `FLUX_PATH` — storage identity (where in git the manifests live).

The bootstrap script defaults to `clusters/kind-lab` (our canonical tree),
**not** to `clusters/${CLUSTER_NAME}`. For multi-cluster setup that lets you
reuse the same GitOps tree via **branch tweaks** (e.g., test-e2e branch has
MetalLB slice 192.168.97.180-199 instead of prod .200-250 + kind apiServerPort
6444 instead of 6443).

Additionally needed tweaks in the test branch (already done):

- `clusters/kind-lab/infrastructure/configs/metallb-pool.yaml` — IP slice
  non-overlap with prod.
- `kind/cluster.yaml` — different cluster name + apiServerPort to avoid conflict
  with main's 6443.

After cluster-up + flux-bootstrap the test cluster reconciles the same GitOps
tree as prod, but with branch-specific tweaks. Demonstrates GitOps
**branch-per-env** pattern (as opposed to path-per-env where git has a separate
directory per cluster).

## Make targets

| target                | what it does                                       |
| --------------------- | -------------------------------------------------- |
| `make prereqs`        | check tools, gh auth, env vars                     |
| `make cluster-up`     | create kind cluster on OrbStack subnet             |
| `make flux-bootstrap` | gh repo create + flux bootstrap github             |
| `make seal`           | kubeseal helper for secrets (stdin → SealedSecret) |
| `make status`         | nodes + flux state                                 |
| `make cluster-down`   | tear down everything                               |

## Structure

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
    │   ├── controllers/                      # Helm releases:
    │   │   ├── cert-manager.yaml             #   cert-manager + trust-manager
    │   │   ├── gateway-api.yaml              #   Gateway API CRDs
    │   │   ├── kubeseal.yaml                 #   sealed-secrets controller
    │   │   └── metallb.yaml                  #   MetalLB (L2 mode)
    │   └── configs/                          # Cluster-scoped configs:
    │       ├── cert-manager-issuers.yaml     #   selfsigned bootstrap → lab-ca
    │       ├── metallb-pool.yaml             #   IPAddressPool + L2Advertisement
    │       └── trust-bundle.yaml             #   lab-ca-bundle (trust-manager)
    └── apps/
        ├── base/
        │   ├── namespaces.yaml               # ns: agentgateway-system, kagent, headlamp, qdrant
        │   └── sealed/anthropic.yaml         # SealedSecret with Anthropic key
        ├── agentgateway/
        │   ├── controller/controller.yaml    # agentgateway HelmRelease + OCIRepository (digest pinned)
        │   └── routes/
        │       ├── proxy.yaml                # Gateway (HTTPS-only listener)
        │       ├── parameters.yaml           # AgentgatewayParameters (socat sidecar)
        │       ├── ash-ph-lab-wildcard-cert.yaml  # wildcard Certificate
        │       ├── anthropic-backend.yaml    # AgentgatewayBackend + 2 HTTPRoutes
        │       ├── ollama-backend.yaml       # headless Service + EndpointSlice + Backend
        │       ├── kagent-ui-route.yaml      # HTTPRoute → kagent-ui Service
        │       ├── agentgateway-ui-route.yaml # HTTPRoute → admin UI :15010
        │       ├── headlamp-ui-route.yaml    # HTTPRoute → headlamp Service
        │       ├── qdrant-ui-route.yaml      # HTTPRoute → qdrant Service:6333
        │       └── querydoc-mcp-route.yaml   # HTTPRoute → kagent-querydoc Service:8080
        ├── headlamp/
        │   └── controller/                   # Headlamp UI + Flux plugin (initContainer)
        │       ├── helmrepository.yaml       # source: kubernetes-sigs.github.io/headlamp/
        │       └── helmrelease.yaml          # view-only RBAC + 7-day sessionTTL
        ├── qdrant/
        │   └── controller/                   # Qdrant vector DB (HelmRelease + 2 GiB PVC)
        │       ├── helmrepository.yaml
        │       └── helmrelease.yaml
        ├── qdrant-embeddings/                # doc2vec writer Job — populates Qdrant collections
        │   ├── configmap.yaml                # doc2vec config: Ollama embedding + 2 sources
        │   └── job.yaml                      # initContainer git-clone + doc2vec writer container
        └── kagent/
            ├── controller/controller.yaml    # kagent HelmRelease (postRenderer) + OCIRepository
            ├── stubs/openai-stub.yaml        # stub Secret applied EARLY (secret-before-pod)
            └── config/
                ├── model-config.yaml         # claude-via-gateway ModelConfig
                ├── qwen-model-config.yaml    # qwen-via-gateway ModelConfig
                ├── agent-trust-stubs.yaml    # 10 chart-managed Agent stubs (label-tagged)
                ├── agent-trust-patch.yaml    # single SMP applied via labelSelector (DRY)
                ├── test-agents.yaml          # git-managed flux-anthropic-test + flux-ollama-test
                ├── doc-agent.yaml            # self-referential RAG agent (uses querydoc tools)
                └── querydoc-mcp.yaml         # RemoteMCPServer pointing kagent at querydoc
```

## Why these choices

- **kind + OrbStack** instead of Docker Desktop: cleaner Mac↔cluster networking,
  MetalLB L2 mode just works (Docker Desktop ARP black-hole avoided).
- **Sealed Secrets** instead of External Secrets/VSO: one controller, kubeseal
  CLI, RSA-encrypted secrets committed to git. Auto-backup RSA pair script —
  survives cluster recreate.
- **cert-manager + trust-manager** instead of manual cert mounts: declarative
  CA + automatic Bundle distribution. Single source of truth for TLS in lab.
- **agentgateway** as LLM proxy: provider abstraction, native Gateway API,
  policy hooks (auth, rate limit). In lab — also plays the ingress role.
- **provider=OpenAI in ModelConfigs** (with gateway translation to Anthropic):
  workaround for agentgateway tool_choice parser bug. kagent ADK generates
  OpenAI-format body → gateway translates → Anthropic native → 200 OK.
- **Ollama as headless Service + EndpointSlice**: cluster-internal abstraction
  over Mac host IP. Pods see a regular Service from the MetalLB pool's
  perspective.

## Known limitations (lab-specific)

- **Self-signed CA** — browsers warn on first visit, accept once. Don't carry to
  prod without a real CA (Let's Encrypt + ExternalDNS).
- **NetworkPolicy absent** — agent pods can reach anything in the cluster.
  Production would add zone separation via CNI policies.
- **Fake API keys in stub Secrets** — `kagent-openai` has
  `fake-not-validated-at-init` because real auth happens gateway-side. Pragmatic
  for lab, but anti-pattern if a pod ever bypasses the gateway.
- **Default Pod Security Standards** — kagent agents run with permissive PSS.
  Restricted PSS would need extra config.
- **DNS by hand on the router** — no ExternalDNS controller. A prod-style lab
  would add external-dns + RFC2136 or cloud provider.
- **agentgateway admin UI exposed without auth** —
  `https://agentgateway.ash.ph.lab` serves live xDS dump, route config, secret
  refs to anyone who resolves DNS. Intentionally kept in lab — admin UI is handy
  for debugging architecture. For prod: OAuth2-proxy + OIDC (GitHub/Google) in
  front of HTTPRoute, or remove HTTPRoute entirely and access only via
  `kubectl port-forward`.
- **`provider: OpenAI` as workaround for agentgateway tool_choice parser bug** —
  ADK generates OpenAI body → gateway translates to Anthropic native.
  Intentional workaround. Track the upstream issue for returning to
  `provider: Anthropic` once the bug is fixed.
- **Single-replica deployments without PodDisruptionBudget** — `kubectl drain`
  or node maintenance triggers downtime. Production would add `replicas: 2+`
  - `PDB minAvailable: 1` for all stateless components.
- **Permanent `debug` logging in agentgateway** — full request bodies (with API
  keys, prompts) in stdout. Convenient for lab troubleshooting, but production
  should route logs via a collector with redaction (cosign-style downstream
  filtering) before storage.
- **Single-replica MetalLB controller + speaker per worker** — single point of
  LB IP allocation failure. Multi-replica + leader election preferred in prod.
- **No observability stack** (Prometheus, OTel, Grafana, Loki) — see Roadmap
  below for the planned OTel Collector + Vector + log-redaction pipeline.

## Forks & dependencies

A few of the images consumed by this lab come from our own forks rather than
upstream — see [`FORKS.md`](FORKS.md) for per-fork rationale, upstream PR links,
and the convergence plan once changes land in their respective upstream
projects.

## Roadmap

### Supply-chain hardening (partial gitless OCI GitOps)

Move from today's "Git source + OCI-pinned vendor charts" to a **two-layer trust
model** where own manifests are also signed OCI artifacts:

- **CI render + push** — GitHub Actions runs `kustomize build` on every path
  under `clusters/kind-lab/`, packs the rendered YAML as an OCI artifact, and
  `oras push`-es it to `ghcr.io/<owner>/kagent-flux-lab/manifests:<sha>`.
- **Cosign keyless signing** — Fulcio + GitHub OIDC, no key custody. Signer
  identity is the workflow ref; transparency log lives in Sigstore Rekor.
- **Flux `OCIRepository.spec.verify`** — source-controller refuses to pull the
  artifact unless the cosign signature matches the configured
  `matchOidcIdentity` (issuer + subject regex).
- **Kyverno `ClusterPolicy` with `verifyImages`** — admission-time second layer.
  Flux already verifies on pull, but Kyverno catches out-of-band `kubectl apply`
  from a compromised admin path.
- **SLSA L3 provenance** (optional) — `slsa-github-generator` emits an
  `.intoto.jsonl` attestation pushed alongside the artifact; Kyverno policy can
  require both signature + provenance.

### Other planned extensions

- **Observability stack** — OTel Collector for metrics/traces → Prometheus +
  Grafana (UI exposed at `tracing.ash.ph.lab`); **Vector** as the log-shipping
  pipeline between agentgateway stdout and Loki, with a `redact` transform to
  mask Anthropic API keys and prompt bodies on the `debug`-level traffic before
  storage.
- **NetworkPolicy / Cilium zone separation** — agents may egress only to
  `agentgateway-proxy`; the proxy may egress only to `api.anthropic.com` and the
  Mac-host Ollama port. Default-deny everywhere else.
- **PodDisruptionBudget + `replicas: 2`** for `agentgateway`, `kagent`, and
  MetalLB controller, so `kubectl drain` survives without downtime.
- **OAuth2-proxy + OIDC** in front of `agentgateway.ash.ph.lab` to gate the
  admin UI (xDS / route config / secret refs) behind GitHub or Google login.
- **External-DNS** with RFC2136 or cloud-provider controller, replacing the
  hand-maintained DNS entries on the home router.
- **Provider switch back to native Anthropic** in ModelConfigs once the upstream
  `tool_choice` parser bug is fixed (we currently use `provider: OpenAI` with
  gateway-side translation as a workaround).

### Documentation TODO

- **Day 2 upgrade workflow** — explicit recipe for bumping a vendor chart
  (`crane digest` → update `ref.tag` + `ref.digest` → `git push` →
  `flux reconcile`).
- **`make smoke-test` recipe** — end-to-end happy-path verifier: DNS resolves,
  HTTPS handshake against the lab CA, kagent → Claude round-trip returns a 200
  with a sane body, in-cluster `SSL_CERT_FILE` mount is populated.
- **Mermaid sequence diagram** — browser → kagent UI → agentgateway → Anthropic,
  annotated with TLS handoff, SSE streaming, and trust-bundle lookup.
