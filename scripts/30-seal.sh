#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

# ---- Defaults (override via env or args) ------------------------------------
SECRET_NAME="${NAME:-anthropic-api}"
NAMESPACE="${NS:-kagent}"
KEY_NAME="${KEY:-ANTHROPIC_API_KEY}"
OUTPUT_PATH="${OUTPUT:-clusters/kind-lab/apps/sealed/anthropic.yaml}"

CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
CONTROLLER_NS="${CONTROLLER_NS:-sealed-secrets}"

G="\033[32m"; R="\033[31m"; Y="\033[33m"; X="\033[0m"
say()  { echo -e "${G}==>${X} $*"; }
err()  { echo -e "${R}!!!${X} $*" >&2; }
warn() { echo -e "${Y}-->${X} $*"; }

# ---- 1. Read raw value from env (never written to disk in plaintext) --------
RAW_VALUE="${!KEY_NAME:-}"
if [ -z "$RAW_VALUE" ]; then
  err "Env var '${KEY_NAME}' is empty. Source .envrc or export the key first."
  exit 1
fi
say "Sealing secret '${NAMESPACE}/${SECRET_NAME}' (key=${KEY_NAME}, ${#RAW_VALUE} chars)"

# ---- 2. Verify controller is reachable --------------------------------------
if ! kubectl get pod -n "${CONTROLLER_NS}" -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1; then
  err "sealed-secrets controller pods not found in ns '${CONTROLLER_NS}'"
  exit 1
fi

# ---- 3. Generate Secret manifest in-memory, pipe to kubeseal ---------------
mkdir -p "$(dirname "$OUTPUT_PATH")"

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal="${KEY_NAME}=${RAW_VALUE}" \
  --dry-run=client \
  -o yaml \
| kubeseal \
  --controller-name "${CONTROLLER_NAME}" \
  --controller-namespace "${CONTROLLER_NS}" \
  --format yaml \
> "${OUTPUT_PATH}"

say "Sealed manifest → ${OUTPUT_PATH}"
echo
say "Diff (encrypted blob is base64 of RSA-encrypted bytes):"
grep -A1 'encryptedData:' "${OUTPUT_PATH}" | head -4
echo
say "Commit and push → Flux applies → Secret '${NAMESPACE}/${SECRET_NAME}' should appear in cluster."
