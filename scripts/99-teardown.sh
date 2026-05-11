#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

CLUSTER_NAME="${CLUSTER_NAME:-kind-lab}"
CPK_PIDFILE="/tmp/cloud-provider-kind.pid"

G="\033[32m"; Y="\033[33m"; X="\033[0m"
say()  { echo -e "${G}==>${X} $*"; }
warn() { echo -e "${Y}-->${X} $*"; }

# ---- Backup sealed-secrets key BEFORE delete (so re-seal isn't needed on recreate) ----
say "Backing up sealed-secrets key (if cluster reachable)..."
bash "$(dirname "$0")/40-key-backup.sh" || warn "key backup failed (non-fatal — DR may require re-seal)"

# ---- Stop cloud-provider-kind (legacy) ----
if [ -f "$CPK_PIDFILE" ] && kill -0 "$(cat "$CPK_PIDFILE")" 2>/dev/null; then
  say "Stopping cloud-provider-kind (pid $(cat "$CPK_PIDFILE"))"
  kill "$(cat "$CPK_PIDFILE")" || true
  rm -f "$CPK_PIDFILE"
fi

# ---- Delete cluster ----
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  say "Deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
else
  say "No cluster named '${CLUSTER_NAME}'"
fi

say "Teardown complete."
