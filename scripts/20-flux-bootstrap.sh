#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

CLUSTER_NAME="${CLUSTER_NAME:-kind-lab}"
GITHUB_USER="${GITHUB_USER:?GITHUB_USER not set — fill .envrc}"
GITHUB_REPO="${GITHUB_REPO:-kagent-flux-lab}"
# Default branch = currently checked-out branch. Lets the attendee `git checkout
# lab-2` (or any lab baseline branch) and have `make full` bootstrap Flux
# against THAT branch — preserves the frozen-lab guarantee. Explicit
# GITHUB_BRANCH env var still overrides for advanced workflows.
DETECTED_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
GITHUB_BRANCH="${GITHUB_BRANCH:-$DETECTED_BRANCH}"
# FLUX_PATH = path in git to the GitOps tree (where infrastructure.yaml + apps.yaml live).
# Previously default = clusters/${CLUSTER_NAME}, but that **couples** two
# independent concepts:
#   - CLUSTER_NAME — runtime identifier (kind container name, kubectl context)
#   - FLUX_PATH — storage identity (where manifests live in git)
# For multi-cluster setups (test cluster reusing a prod GitOps tree via branch
# tweaks instead of a separate path) this coupling breaks. Hence hardcoded default
# to the canonical path; multi-env setups override via env var.
FLUX_PATH="${FLUX_PATH:-clusters/kind-lab}"

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

# ---- 2. Rename branch to GITHUB_BRANCH only on fresh init ------------------
# Skip rename when caller is already on a named branch — assumes the attendee
# intentionally checked out `lab-2` / `lab-3` / `main` etc. Rename only fires
# when the script is run inside a freshly `git init`'d repo where the default
# branch is `master` (or empty) and the target is `main`.
CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$CURRENT_BRANCH" = "master" ] && [ "$GITHUB_BRANCH" = "main" ]; then
  say "Fresh repo on master — renaming local branch master → main"
  git branch -m "$GITHUB_BRANCH"
elif [ "$CURRENT_BRANCH" != "$GITHUB_BRANCH" ] && [ -n "$CURRENT_BRANCH" ]; then
  warn "On branch '$CURRENT_BRANCH' but GITHUB_BRANCH='$GITHUB_BRANCH' — leaving local branch alone."
  warn "Flux source will point at '$GITHUB_BRANCH'. Set GITHUB_BRANCH=$CURRENT_BRANCH if that's wrong."
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
say "Bootstrap done. Next: git push to ${GITHUB_BRANCH} — Flux reconciles the rest."
say "Watch progress: flux get kustomizations -A"
