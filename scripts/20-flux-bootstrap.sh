#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

CLUSTER_NAME="${CLUSTER_NAME:-kind-lab}"
GITHUB_USER="${GITHUB_USER:?GITHUB_USER not set — fill .envrc}"
GITHUB_REPO="${GITHUB_REPO:-kagent-flux-lab}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
FLUX_PATH="${FLUX_PATH:-clusters/${CLUSTER_NAME}}"

G="\033[32m"; R="\033[31m"; Y="\033[33m"; X="\033[0m"
say()  { echo -e "${G}==>${X} $*"; }
err()  { echo -e "${R}!!!${X} $*" >&2; }
warn() { echo -e "${Y}-->${X} $*"; }

# ---- 0. Defensive: refuse to commit if .envrc somehow not gitignored --------
if git ls-files --error-unmatch .envrc >/dev/null 2>&1; then
  err ".envrc is tracked in git! Remove from index before continuing."
  exit 1
fi

# ---- 1. Initial commit if repo empty ---------------------------------------
if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
  say "Empty repo — creating initial commit"
  git add -A
  git status --short
  git commit -m "feat: initial scripts, kind cluster config, README"
fi

# ---- 2. Rename branch to GITHUB_BRANCH if needed ---------------------------
CURRENT_BRANCH=$(git symbolic-ref --short HEAD)
if [ "$CURRENT_BRANCH" != "$GITHUB_BRANCH" ]; then
  say "Renaming local branch ${CURRENT_BRANCH} → ${GITHUB_BRANCH}"
  git branch -m "$GITHUB_BRANCH"
fi

# ---- 3. Create or sync GitHub repo -----------------------------------------
if gh repo view "${GITHUB_USER}/${GITHUB_REPO}" >/dev/null 2>&1; then
  say "GitHub repo ${GITHUB_USER}/${GITHUB_REPO} already exists"
  if ! git remote get-url origin >/dev/null 2>&1; then
    say "Adding origin remote"
    git remote add origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
  fi
  say "Pushing local commits to origin/${GITHUB_BRANCH}"
  git push -u origin "${GITHUB_BRANCH}" || warn "push had no effect (maybe up-to-date)"
else
  say "Creating GitHub repo ${GITHUB_USER}/${GITHUB_REPO} (public)"
  gh repo create "${GITHUB_REPO}" --public --source=. --remote=origin --push
fi

# ---- 4. Flux bootstrap (idempotent — re-runs are safe) ---------------------
export GITHUB_TOKEN
GITHUB_TOKEN=$(gh auth token)

say "Bootstrapping Flux → ${GITHUB_USER}/${GITHUB_REPO} path=${FLUX_PATH}"
flux bootstrap github \
  --owner="${GITHUB_USER}" \
  --repository="${GITHUB_REPO}" \
  --branch="${GITHUB_BRANCH}" \
  --path="${FLUX_PATH}" \
  --personal \
  --token-auth

# ---- 5. Pull manifests Flux pushed -----------------------------------------
say "Pulling flux-system manifests"
git pull --rebase origin "${GITHUB_BRANCH}"

# ---- 6. Status -------------------------------------------------------------
echo
say "Flux components:"
flux get all -A
echo
say "Phase 3 done. Next: scripts/30-infra-deploy.sh (Phase 4 — MetalLB + Sealed Secrets)"
