.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

CLUSTER_NAME ?= kind-lab

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n\nTargets:\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: prereqs
prereqs: ## Check required tools, gh auth, env vars
	@bash scripts/00-prereqs.sh

.PHONY: cluster-up
cluster-up: prereqs ## Create kind cluster + auto-restore sealed-secrets key (if backup exists)
	@bash scripts/10-cluster-up.sh
	@bash scripts/15-key-restore.sh

.PHONY: flux-bootstrap
flux-bootstrap: ## Create GitHub repo + bootstrap Flux
	@bash scripts/20-flux-bootstrap.sh

.PHONY: seal
seal: ## Seal a secret from stdin (usage: make seal NAME=anthropic NS=agentgateway-system FIELD=Authorization ENV_VAR=ANTHROPIC_API_KEY)
	@bash scripts/30-seal.sh

.PHONY: key-backup
key-backup: ## Backup sealed-secrets RSA pair → ~/.sealed-secrets-keys/<cluster>.yaml
	@bash scripts/40-key-backup.sh

.PHONY: key-restore
key-restore: ## Restore sealed-secrets RSA pair from backup (no-op if missing)
	@bash scripts/15-key-restore.sh

.PHONY: cluster-down
cluster-down: ## Auto-backup sealed-secrets key + delete kind cluster
	@bash scripts/99-teardown.sh

.PHONY: git-status
git-status: ## Show what would be committed (sanity check)
	@git status

.PHONY: status
status: ## Show cluster nodes + Flux status
	@echo "== Nodes =="; kubectl get nodes -o wide; echo
	@echo "== Flux =="; flux get all 2>/dev/null || echo "(flux not bootstrapped yet)"
