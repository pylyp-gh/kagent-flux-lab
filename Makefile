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
cluster-up: prereqs ## Create kind cluster + start cloud-provider-kind
	@bash scripts/10-cluster-up.sh

.PHONY: flux-bootstrap
flux-bootstrap: ## Create GitHub repo + bootstrap Flux
	@bash scripts/20-flux-bootstrap.sh

.PHONY: git-status
git-status: ## Show what would be committed (sanity check)
	@git status

.PHONY: seal
seal: ## Seal a secret from stdin (usage: make seal NAME=anthropic NS=kagent KEY=ANTHROPIC_API_KEY)
	@bash scripts/30-seal.sh

.PHONY: cluster-down
cluster-down: ## Delete kind cluster + stop cloud-provider-kind
	@bash scripts/99-teardown.sh

.PHONY: status
status: ## Show cluster nodes + Flux status
	@echo "== Nodes =="; kubectl get nodes -o wide; echo
	@echo "== Flux =="; flux get all 2>/dev/null || echo "(flux not bootstrapped yet)"
