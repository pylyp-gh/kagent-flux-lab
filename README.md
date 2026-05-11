# kagent-flux-lab

End-to-end GitOps lab: **kind/OrbStack** → **Flux CD** → **Sealed Secrets** →
**cert-manager + trust-manager** → **MetalLB** → **Gateway API + agentgateway**
→ **kagent** → **Anthropic Claude / Ollama**. Все HTTPS-only через єдиний
`agentgateway` ingress.

Ціль — мінімум ручної роботи, максимум через `make` + git push. Все інфра-стан
декларативно живе в окремій GitHub репі, керується Flux.

## Топологія

```
┌──────────────────────────────────────────────────────────────────┐
│  kind cluster (3 nodes на OrbStack)                              │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │  Flux CD ◄──── git push ──── GitHub repo                  │   │
│  │     │                                                     │   │
│  │     ├─► sealed-secrets (RSA key auto-backup/restore)      │   │
│  │     ├─► metallb (L2 pool 192.168.97.200-250)              │   │
│  │     ├─► gateway-api CRDs (v1.5.0 experimental)            │   │
│  │     ├─► cert-manager + trust-manager                      │   │
│  │     │     └─► lab-ca self-signed Root CA                  │   │
│  │     │     └─► wildcard cert *.lab.local + in-cluster SANs │   │
│  │     │     └─► Bundle → ConfigMap у kagent + agentgateway  │   │
│  │     ├─► agentgateway (LLM proxy + Gateway API impl)       │   │
│  │     │     └─► AgentgatewayBackend: anthropic + ollama     │   │
│  │     │     └─► HTTPS-only listener (HTTP видалений)        │   │
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
│     • https://kagent.lab.local       → kagent-ui Service         │
│     • https://agentgateway.lab.local → agentgateway-proxy:15010  │
│     • https://...local/v1/messages   → AgentgatewayBackend       │
│     • https://...local/ollama/...    → Mac host Ollama           │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
            api.anthropic.com (через gateway) │ Mac host Ollama 11434
```

## Networking & TLS

**Один Service `LoadBalancer` на весь stack** — `agentgateway-proxy` тримає один
MetalLB IP `192.168.97.200`. Усі HTTP(S) запити (від browser до UI, від
in-cluster pod до моделі) проходять через цей gateway. Це **production inspired
pattern** — `agentgateway` грає роль ingress + LLM router водночас.

**HTTPS-only.** Browser потребує Secure Context для Web Crypto API
(`crypto.randomUUID()` у Next.js UI). Тому HTTP listener видалено повністю —
`http://` reach до port 80 timeout-ить. Cert підписаний self-signed CA (`lab-ca`
ClusterIssuer); browser показує warning один раз → accept.

**In-cluster TLS trust.** kagent agent pods ходять до моделі через
`https://agentgateway-proxy.agentgateway-system.svc.cluster.local`. Cert має
extended SANs для in-cluster Service DNS (всі варіанти від короткого hostname до
FQDN). Pods читають lab-ca через **trust-manager Bundle** → ConfigMap у `kagent`
ns → mounted у pod → `SSL_CERT_FILE` env. Python httpx бачить bundle, TLS
handshake проходить.

**DNS на home router** — `kagent.lab.local` і `agentgateway.lab.local`
резолвлять у `192.168.97.200` (MetalLB IP) на всіх пристроях у LAN.

## agentgateway як єдиний ingress

Один Gateway resource `agentgateway-proxy` обслуговує:

- **UI traffic** (HTTPRoute з `backendRef.kind=Service`) — kagent UI, gateway
  admin UI
- **LLM API traffic** (HTTPRoute з `backendRef.kind=AgentgatewayBackend`) —
  Anthropic Messages, Anthropic-flavored OpenAI completions, Ollama

Hostname-based routing розводить UI vs API:

- `*.lab.local` SNI → wildcard cert
- HTTPRoutes з конкретним `hostnames:` claim'аяють свій subdomain
- HTTPRoutes без `hostnames:` (anthropic, ollama) ловлять in-cluster requests
  через Service DNS

Це **replaces traditional ingress controller** (nginx-ingress, traefik) + **LLM
proxy layer** (LiteLLM, OpenRouter) у одну сутність. Trade-off — менше гнучкості
ніж окремі шари, але швидше для lab.

## Quick start

```bash
cp .envrc.example .envrc
# заповни ANTHROPIC_API_KEY, GITHUB_USER
direnv allow .

make prereqs          # перевірити tools, gh auth, env
make cluster-up       # kind + MetalLB-ready network
make flux-bootstrap   # створити GitHub репу + Flux GitOps
# далі — все через git push у Flux репу

# після bootstrap (~5 min reconcile):
# 1. додати DNS на router: kagent.lab.local + agentgateway.lab.local → MetalLB IP
# 2. (опційно) додати lab-ca cert у Keychain trust → не побачиш browser warning
```

## Make targets

| target                | що робить                                           |
| --------------------- | --------------------------------------------------- |
| `make prereqs`        | перевірка tools, gh auth, env vars                  |
| `make cluster-up`     | створити kind cluster на OrbStack subnet            |
| `make flux-bootstrap` | gh repo create + flux bootstrap github              |
| `make seal`           | kubeseal helper для секретів (stdin → SealedSecret) |
| `make status`         | nodes + flux state                                  |
| `make cluster-down`   | прибрати все                                        |

## Структура

```
.
├── scripts/                          # bash entry points (idempotent)
├── kind/cluster.yaml                 # kind cluster spec
└── clusters/kind-lab/                # GitOps tree
    ├── flux-system/                  # auto-generated by flux bootstrap
    ├── infrastructure/
    │   ├── controllers/              # Helm: sealed-secrets, metallb,
    │   │                             #       cert-manager, trust-manager,
    │   │                             #       gateway-api CRDs
    │   └── configs/                  # IPAddressPool, L2Advertisement,
    │                                 #   Issuers, trust Bundle
    └── apps/
        ├── agentgateway/
        │   ├── controller/           # agentgateway HelmRelease
        │   └── routes/               # Gateway, HTTPRoutes,
        │                             #   AgentgatewayBackends,
        │                             #   wildcard Certificate
        └── kagent/
            ├── controller/           # kagent HelmRelease з postRenderer
            └── config/               # ModelConfigs, Secret stubs,
                                      #   Agent trust patches,
                                      #   git-managed test agents
```

## Why these choices

- **kind + OrbStack** замість Docker Desktop: чистіший Mac↔cluster networking,
  MetalLB L2 mode працює без проблем (Docker Desktop ARP-чорнота).
- **Sealed Secrets** замість External Secrets/VSO: один controller, kubeseal
  CLI, RSA-encrypted secrets можна commit'ити в Git. Auto-backup RSA pair скрипт
  — survive cluster recreate.
- **cert-manager + trust-manager** замість manual cert mounts: declarative CA +
  automatic Bundle distribution. Single source of truth для TLS у lab.
- **agentgateway** як LLM proxy: provider abstraction, native Gateway API,
  policy hooks (auth, rate limit). У lab — також ingress role.
- **provider=OpenAI у ModelConfigs** (через gateway translation до Anthropic):
  workaround agentgateway tool_choice parser bug. Кagent ADK генерує
  OpenAI-format body → gateway translate → Anthropic native → 200 OK.
- **Ollama як headless Service + EndpointSlice**: cluster-internal abstraction
  над Mac host IP. Pods думають що це звичайний Service, з MetalLB pool
  perspective.

## Known limitations (lab-specific)

- **Self-signed CA** — browsers warn першого разу, accept once. Не варто
  переносити у prod без real CA (Let's Encrypt + ExternalDNS).
- **NetworkPolicy відсутня** — agent pods можуть досягати будь-чого в кластері.
  Production додав би zone separation через CNI policies.
- **Fake API keys у stub Secrets** — `kagent-openai` має
  `fake-not-validated-at-init` бо real auth йде gateway-side. Це pragmatic для
  lab, але антипаттерн якщо pod коли-небудь обходитиме gateway.
- **Default Pod Security Standards** — kagent agents run з permissive PSS.
  Restricted PSS би вимагала extra config.
- **DNS вручну на router** — без ExternalDNS controller. У prod-стилі lab додав
  би external-dns + RFC2136 чи cloud provider.
- **agentgateway admin UI exposed без auth** — `https://agentgateway.lab.local`
  віддає live xDS dump, route config, secret refs усім хто резолвить DNS.
  Свідомо лишено у lab — admin UI зручний для debugging architecture. Для prod:
  OAuth2-proxy + OIDC (GitHub/Google) перед HTTPRoute, або зовсім видалити
  HTTPRoute і access тільки через `kubectl port-forward`.
- **OCI image tags замість digest pinning** — `agentgateway:v2.2.1`,
  `kagent:0.9.2` mutable tags. Registry rewrite → інший image at reconcile. Для
  prod: `crane digest oci://...` → `ref.digest: sha256:...` у OCIRepository.
- **`provider: OpenAI` як workaround agentgateway tool_choice parser bug** — ADK
  генерує OpenAI body → gateway translate до Anthropic native. Це навмисний
  обхід. Track upstream issue для повернення до `provider: Anthropic` якщо bug
  буде виправлений.
