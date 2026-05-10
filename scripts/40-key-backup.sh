#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

CLUSTER_NAME="${CLUSTER_NAME:-kind-lab}"
BACKUP_DIR="${SEALED_KEY_BACKUP_DIR:-$HOME/.sealed-secrets-keys}"
BACKUP_FILE="${BACKUP_DIR}/${CLUSTER_NAME}.yaml"

G="\033[32m"; Y="\033[33m"; R="\033[31m"; X="\033[0m"
say()  { echo -e "${G}==>${X} $*"; }
warn() { echo -e "${Y}-->${X} $*"; }
err()  { echo -e "${R}!!!${X} $*" >&2; }

# Skip if cluster unreachable
if ! kubectl cluster-info >/dev/null 2>&1; then
  warn "Cluster unreachable — nothing to backup."
  exit 0
fi

# Find active sealed-secrets key
KEY_NAME=$(kubectl get secret -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "${KEY_NAME}" ]; then
  warn "No active sealed-secrets key in cluster — nothing to backup."
  exit 0
fi

# Setup backup dir з safe permissions
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

# Export — strip cluster-managed metadata that would conflict on restore
say "Backing up '${KEY_NAME}' → ${BACKUP_FILE}"
kubectl get secret "${KEY_NAME}" -n sealed-secrets -o yaml \
  | yq eval 'del(.metadata.creationTimestamp, .metadata.resourceVersion, .metadata.uid, .metadata.managedFields, .metadata.ownerReferences)' - \
  > "${BACKUP_FILE}"

chmod 600 "${BACKUP_FILE}"
say "Backup created (mode 600): $(wc -c < "${BACKUP_FILE}" | tr -d ' ') bytes"
