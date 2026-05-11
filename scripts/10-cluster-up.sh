#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/_env.sh
. "$(dirname "$0")/_env.sh"

CLUSTER_NAME="${CLUSTER_NAME:-kind-lab}"
KIND_CONFIG="kind/cluster.yaml"

G="\033[32m"; R="\033[31m"; Y="\033[33m"; X="\033[0m"
say()  { echo -e "${G}==>${X} $*"; }
err()  { echo -e "${R}!!!${X} $*" >&2; }
warn() { echo -e "${Y}-->${X} $*"; }

# ---- 1. Create kind cluster (idempotent) ------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  say "Cluster '${CLUSTER_NAME}' already exists — skipping kind create."
else
  say "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}"
fi

# ---- 2. Set kubectl context -------------------------------------------------
say "Switching kubectl context to kind-${CLUSTER_NAME}"
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ---- 3. Show cluster info ---------------------------------------------------
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
echo
kubectl get nodes -o wide

# ---- 4. Inspect docker network 'kind' (used to size MetalLB pool) -----------
echo
say "Docker 'kind' network info (for MetalLB IPAddressPool sizing)"
SUBNET_V4=$(docker network inspect kind --format '{{range .IPAM.Config}}{{if not (contains .Subnet ":")}}{{.Subnet}}{{end}}{{end}}' 2>/dev/null || true)
# fallback: just grab first non-IPv6 subnet line
SUBNET_V4=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -v ':' | head -1)
echo "  IPv4 subnet : ${SUBNET_V4:-unknown}"
echo "  Reserved    : $(docker network inspect kind --format '{{range .Containers}}{{.IPv4Address}} {{end}}' | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')"
warn "MetalLB pool must live within this subnet — verify clusters/kind-lab/infrastructure/configs/metallb-pool.yaml"

echo
say "Cluster ready. LoadBalancer IPs come up once MetalLB deploys via Flux."
say "Next: make flux-bootstrap"
