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

## Adding more forks here

When a new component needs a fork:

- Open a PR upstream first; iterate on the PR branch, not on `main`.
- Document the **why** in this file (link from code comments).
- Keep digest-pinned image references in K8s manifests; refresh digests with
  `crane digest <ref>` when bumping the branch.
- When the PR lands upstream, edit this file's "Convergence plan" section + flip
  image references in one commit titled
  `chore(deps): switch X back to upstream after upstream-PR land`.
