#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

G="\033[32m"; R="\033[31m"; Y="\033[33m"; X="\033[0m"
ok()   { echo -e "${G}✓${X} $*"; }
err()  { echo -e "${R}✗${X} $*"; }
warn() { echo -e "${Y}!${X} $*"; }

missing=0

require_cmd() {
  local cmd=$1
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd"
  else
    err "$cmd not found"
    missing=$((missing+1))
  fi
}

echo "== Required CLIs =="
for t in docker kind kubectl flux kubeseal gh helm yq jq cloud-provider-kind; do
  require_cmd "$t"
done

echo ""
echo "== Docker daemon =="
if docker info >/dev/null 2>&1; then
  ok "Docker running ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))"
else
  err "Docker daemon not running. Start Docker Desktop."
  missing=$((missing+1))
fi

echo ""
echo "== gh auth =="
if gh auth status >/dev/null 2>&1; then
  ok "gh authenticated as $(gh api user --jq .login 2>/dev/null || echo unknown)"
else
  err "gh not authenticated. Run: gh auth login"
  missing=$((missing+1))
fi

echo ""
echo "== Env vars =="
: "${CLUSTER_NAME:=kind-lab}"
: "${GITHUB_REPO:=kagent-flux-lab}"
: "${GITHUB_BRANCH:=main}"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ok "ANTHROPIC_API_KEY set (${#ANTHROPIC_API_KEY} chars)"
else
  err "ANTHROPIC_API_KEY not set. Copy .envrc.example → .envrc, fill, then: direnv allow ."
  missing=$((missing+1))
fi
ok "CLUSTER_NAME=${CLUSTER_NAME}"
ok "GITHUB_REPO=${GITHUB_REPO}"
ok "GITHUB_BRANCH=${GITHUB_BRANCH}"

echo ""
if [ "$missing" -gt 0 ]; then
  err "Missing $missing prerequisite(s) — fix above and rerun."
  exit 1
fi
ok "All prerequisites satisfied."
