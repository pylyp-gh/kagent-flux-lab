#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

# ---- Inputs (override via env) ---------------------------------------------
SECRET_NAME="${NAME:-anthropic-secret}"
NAMESPACE="${NS:-agentgateway-system}"

# ENV_VAR — name of shell env var holding the raw value
# FIELD   — name of the field inside the resulting Secret
# (different concepts: agentgateway expects field "Authorization" regardless of provider)
ENV_VAR="${ENV_VAR:-ANTHROPIC_API_KEY}"
FIELD="${FIELD:-Authorization}"

# OUTPUT_PATH = where to write the sealed manifest. Default matches current
# GitOps layout (apps/base/sealed/anthropic.yaml — actual location).
# Override via OUTPUT=... for other secrets or new clusters.
OUTPUT_PATH="${OUTPUT:-clusters/kind-lab/apps/base/sealed/anthropic.yaml}"
CONTROLLER_NAME="${CONTROLLER_NAME:-sealed-secrets-controller}"
CONTROLLER_NS="${CONTROLLER_NS:-sealed-secrets}"

G="\033[32m"; R="\033[31m"; X="\033[0m"
say() { echo -e "${G}==>${X} $*"; }
err() { echo -e "${R}!!!${X} $*" >&2; }

RAW_VALUE="${!ENV_VAR:-}"
if [ -z "$RAW_VALUE" ]; then
  err "Env var '${ENV_VAR}' is empty. Source .envrc or export it first."
  exit 1
fi

say "Sealing '${NAMESPACE}/${SECRET_NAME}' (field='${FIELD}', source env='${ENV_VAR}', ${#RAW_VALUE} chars)"

if ! kubectl get pod -n "${CONTROLLER_NS}" -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1; then
  err "sealed-secrets controller pods not found in ns '${CONTROLLER_NS}'"
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal="${FIELD}=${RAW_VALUE}" \
  --dry-run=client \
  -o yaml \
| kubeseal \
  --controller-name "${CONTROLLER_NAME}" \
  --controller-namespace "${CONTROLLER_NS}" \
  --format yaml \
> "${OUTPUT_PATH}"

say "Sealed manifest → ${OUTPUT_PATH}"
echo
say "Encrypted blob is base64 of RSA-encrypted bytes; namespace+name are bound into ciphertext."
