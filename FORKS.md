# Upstream forks + dependencies

This lab depends on a few forked components beyond their upstream sources. Each
entry below explains **why** the fork exists, **what** it changes, and the
**plan to converge** back to upstream once changes land. Code references this
file from inline comments — the goal is one authoritative document that survives
image bumps and code refactors without divergence.

## `kagent-dev/doc2vec` → `pylyp-gh/doc2vec`

**Used by**:

- writer Job — `clusters/kind-lab/apps/qdrant-embeddings/job.yaml`
- querydoc MCP server image —
  `clusters/kind-lab/apps/kagent/controller/controller.yaml` (querydoc subchart
  image override)

**Upstream PR**: <https://github.com/kagent-dev/doc2vec/pull/82> —
`feat(embeddings): support custom OpenAI baseURL for Ollama / OpenAI-compatible providers`.

**Changes on the `feat/openai-base-url` branch (PR scope)**:

1. **`embedding.openai.base_url` config field + `OPENAI_BASE_URL` env fallback**
   in the writer (`doc2vec.ts`). Upstream hard-codes `https://api.openai.com/v1`
   in the OpenAI SDK constructor — no way to target Ollama or any other
   OpenAI-compatible embedding endpoint without modifying the code. The PR adds
   the field, threaded into `new OpenAI({ ..., baseURL })` via conditional
   spread — zero behavior change when the field is unset, so
   backwards-compatible for everyone not running a local stack.
2. **Same fix in the reader MCP server** (`mcp/src/index.ts`). The MCP server
   also embeds the user's query before vector search, so it needs the same
   redirectable baseURL.
3. **`Dockerfile` rebuild step for `better-sqlite3`**. Upstream root Dockerfile
   uses `npm install --ignore-scripts` (security best practice — blocks
   malicious postinstall scripts) but omits the explicit
   `npm rebuild better-sqlite3` afterwards. Native binding never compiles on
   architectures lacking a prebuild (arm64 + Node 20) — runtime fails with
   "Could not locate the bindings file". The PR adds the rebuild as a separate,
   targeted step.

**Lab-only changes (not upstreamed) on the `lab2-build` branch**:

4. **`mcp/Dockerfile` base image swap**: upstream uses
   `cgr.dev/chainguard/wolfi-base:latest` which (a) requires
   `chainctl auth login` Docker credential helper wiring to pull (friction for
   casual contributors), and (b) ships bleeding-edge Node (26+) which is too new
   for `better-sqlite3` 11.9.1 prebuilds — native rebuild fails with Node ABI
   mismatch. Swapped to `node:22-alpine`: public, no auth ceremony, Node version
   pinned to a stable prebuild matrix. Chainguard's minimal-CVE story is lost,
   but the lab is not a security-hardened production target.

**Convergence plan**:

- Items 1-3 (PR #82): once merged, switch consumers back to
  `ghcr.io/kagent-dev/doc2vec` (writer) and `ghcr.io/kagent-dev/doc2vec/mcp`
  (reader). Digests pinned in manifests guarantee no surprise switch — bump
  intentionally with `crane digest`.
- Item 4 (Chainguard swap): stays out of upstream — environmental friction not
  warranting a contribution. If we want it back, switch the `lab2-build` fork
  tag-pins to upstream after the Node version bumps stabilise.

## `techwithhuz/mcp-security-governance` → `pylyp-gh/mcp-security-governance`

**Used by**:

- HelmRelease —
  `clusters/kind-lab/apps/mcp-governance/controller/helmrelease.yaml` (OCI
  source `oci://ghcr.io/pylyp-gh/charts/mcp-governance:0.22.3`)
- Fixed CRD that replaces the buggy chart-bundled one —
  `clusters/kind-lab/apps/mcp-governance/controller/crd-mcpgovernancepolicy.yaml`

**Upstream issue**:
<https://github.com/techwithhuz/mcp-security-governance/issues/27> —
`charts/mcp-governance/crds/mcpgovernancepolicies.yaml` has duplicate YAML keys
under `spec.versions[0].schema.openAPIV3Schema.properties.spec`. The status
fields (phase, clusterScore, lastEvaluationTime, conditions) are stuffed inside
`properties.spec` as a SECOND `type: object` + `properties:` block at the same
indentation. YAML parsers silently overwrite — only the 4 status fields survive
in the schema, and `apiserver` rejects MCPGovernancePolicy CRs with
`field not declared in schema` for every spec field.

**Changes on the fork**:

The fork is **tag-only** — `v0.22.3` was added on top of upstream `main` (commit
`ad81074`) to trigger the upstream's own `.github/workflows/release.yaml`, which
builds multi-arch images and publishes the OCI Helm chart. No code changes in
the fork itself.

Published artifacts on fork's tag:

- `ghcr.io/pylyp-gh/mcp-governance-controller:0.22.3`
- `ghcr.io/pylyp-gh/mcp-governance-dashboard:0.22.3`
- `oci://ghcr.io/pylyp-gh/charts/mcp-governance:0.22.3`

**CRD bug workaround lives in the Flux repo, not the fork** —
`HelmRelease.install.crds: Skip` plus a standalone fixed CRD applied as a
sibling Kustomize resource. This keeps the fork minimal and easy to rebase /
drop when upstream lands the fix.

**One-time fork bootstrap step**: GitHub Packages API does NOT support PATCH
visibility for personal-account packages (UI-only operation). After the first
`v*` tag push to a fresh fork, visit each package's Settings page → "Change
visibility" → Public:

- github.com/users/pylyp-gh/packages/container/mcp-governance-controller
- github.com/users/pylyp-gh/packages/container/mcp-governance-dashboard
- github.com/users/pylyp-gh/packages/container/charts%2Fmcp-governance

Once public, cluster bootstrap (`kind create` → `flux bootstrap`) is fully
automated with no further manual steps per cluster recreation.

**Convergence plan**:

- Once upstream issue #27 lands (CRD fix in mcpgovernancepolicies.yaml), drop
  the standalone fixed CRD from the Flux repo (`crd-mcpgovernancepolicy.yaml`)
  and flip HelmRelease to `crds: CreateReplace`. The fork can then track
  upstream tags directly — no more local tag-only forks needed.

## Adding more forks here

When a new component needs a fork:

- Open a PR upstream first; iterate on the PR branch, not on `main`.
- Document the **why** in this file (link from code comments).
- Keep digest-pinned image references in K8s manifests; refresh digests with
  `crane digest <ref>` when bumping the branch.
- When the PR lands upstream, edit this file's "Convergence plan" section + flip
  image references in one commit titled
  `chore(deps): switch X back to upstream after upstream-PR land`.
