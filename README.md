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
│  Single MetalLB IP 192.168.97.200 → agentgateway-proxy           │
│  ▼ TLS terminate ▼ HTTPRoute SNI/path routing                    │
│     • https://kagent.ash.ph.lab       → kagent-ui Service         │
│     • https://agentgateway.ash.ph.lab → agentgateway-proxy:15010  │
│     • https://...local/v1/messages   → AgentgatewayBackend       │
│     • https://...local/ollama/...    → Mac host Ollama           │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
       api.anthropic.com (TLS) │ Mac host Ollama 11434 (plain HTTP)
       both via agentgateway with translation/forwarding
```

## Networking & TLS

**One `LoadBalancer` Service for the whole stack** — `agentgateway-proxy` holds
a single MetalLB IP `192.168.97.200`. All HTTP(S) traffic (browser → UI,
in-cluster pod → model) flows through this gateway. It's a **production-
inspired pattern** — `agentgateway` plays the role of ingress + LLM router at
the same time.

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

**DNS on home router** — `kagent.ash.ph.lab` and `agentgateway.ash.ph.lab`
resolve to `192.168.97.200` (MetalLB IP) on all devices in the LAN.

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

## Quick start

```bash
cp .envrc.example .envrc
# fill in ANTHROPIC_API_KEY, GITHUB_USER
direnv allow .

make prereqs          # check tools, gh auth, env vars
make cluster-up       # kind + MetalLB-ready network
make flux-bootstrap   # create GitHub repo + Flux GitOps
# from here — everything via git push to the Flux repo

# after bootstrap (~5 min reconcile):
# 1. add DNS on router: kagent.ash.ph.lab + agentgateway.ash.ph.lab → MetalLB IP
# 2. (optional) add lab-ca cert to Keychain trust → no browser warning
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
├── scripts/                          # bash entry points (idempotent)
├── kind/cluster.yaml                 # kind cluster spec
└── clusters/kind-lab/                # GitOps tree
    ├── flux-system/                  # auto-generated by flux bootstrap
    ├── infrastructure.yaml           # Flux Kustomizations: infra-controllers, infra-configs
    ├── apps.yaml                     # Flux Kustomizations: apps-base, *-controller, *-config, kagent-stubs
    ├── infrastructure/
    │   ├── controllers/              # Helm: sealed-secrets, metallb,
    │   │                             #       cert-manager, trust-manager,
    │   │                             #       gateway-api CRDs
    │   └── configs/                  # IPAddressPool, L2Advertisement,
    │                                 #   Issuers, trust Bundle
    └── apps/
        ├── base/                     # Namespace defs + SealedSecret(s)
        │   ├── namespaces.yaml
        │   └── sealed/anthropic.yaml
        ├── agentgateway/
        │   ├── controller/           # agentgateway HelmRelease
        │   └── routes/               # Gateway, HTTPRoutes,
        │                             #   AgentgatewayBackends,
        │                             #   wildcard Certificate
        └── kagent/
            ├── controller/           # kagent HelmRelease with postRenderer
            ├── stubs/                # stub Secrets (applied EARLY,
            │                         #   before kagent HelmRelease — secret-before-pod)
            └── config/               # ModelConfigs, Agent trust patches,
                                      #   git-managed test agents
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
- **No observability stack** (Prometheus, OTel, Grafana, Loki). Phase 12+ — add
  OTel Collector + log redaction.
