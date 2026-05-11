#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

CLUSTER_NAME="${CLUSTER_NAME:-kind-lab}"
BACKUP_DIR="${SEALED_KEY_BACKUP_DIR:-$HOME/.sealed-secrets-keys}"
BACKUP_FILE="${BACKUP_DIR}/${CLUSTER_NAME}.yaml"

G="\033[32m"; Y="\033[33m"; X="\033[0m"
say()  { echo -e "${G}==>${X} $*"; }
warn() { echo -e "${Y}-->${X} $*"; }

# 1. Backup file exists?
if [ ! -f "${BACKUP_FILE}" ]; then
  warn "No backup at ${BACKUP_FILE} — controller will generate fresh keypair (re-seal needed for existing sealed/*.yaml)"
  exit 0
fi

# 2. Cluster reachable?
if ! kubectl cluster-info >/dev/null 2>&1; then
  warn "Cluster unreachable — skipping restore."
  exit 0
fi

# 3. Active key already in cluster? (idempotent — may be re-run)
if kubectl get secret -n sealed-secrets \
     -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     --no-headers 2>/dev/null | grep -q .; then
  say "Active sealed-secrets key already exists in cluster — skip restore."
  exit 0
fi

# 4. Apply backup BEFORE controller starts.
# When sealed-secrets HelmRelease deploys controller, it scans for existing
# active key and adopts it. Critical: this script must run before flux-bootstrap.
say "Restoring sealed-secrets key from ${BACKUP_FILE}"
kubectl create namespace sealed-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${BACKUP_FILE}"
say "Restore complete — controller will adopt this key on install."
