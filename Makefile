# bluedots-devops — Helm deploy orchestrator
#
# Deploy order: platform -> dpg -> aggregator-dpg
#
# Run `make` (or `make help`) to see all targets.
# Run `make install` to deploy the full stack in order.

.DEFAULT_GOAL := help
SHELL := /bin/bash

COMMON_NS      ?= common-services
DPG_NS         ?= dpg
AGG_NS         ?= aggregator

COMMON_REL     ?= platform
DPG_REL        ?= dpg
AGG_REL        ?= aggregator

COMMON_DIR     := ./helm/common-services
DPG_DIR        := ./helm/signals
AGG_DIR        := ./helm/aggregator

# ─── help ──────────────────────────────────────────────────────────────────
help:  ## Show this help
	@awk 'BEGIN{FS=":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	      /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' \
	      $(MAKEFILE_LIST)

# ─── preflight ─────────────────────────────────────────────────────────────
preflight:  ## Verify kubectl + helm + cluster reachable
	@command -v helm    >/dev/null || { echo "ERROR: helm not installed";    exit 1; }
	@command -v kubectl >/dev/null || { echo "ERROR: kubectl not installed"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable; check kubeconfig"; exit 1; }
	@echo "context: $$(kubectl config current-context)"

# ─── 1) platform ───────────────────────────────────────────────────────────
platform-install: preflight  ## [1/3] Install common-services (ingress-nginx + cert-manager + ClusterIssuer + Postgres + Redis)
	@set -euo pipefail; \
	getpw() { kubectl -n $(COMMON_NS) get secret "$$1" -o jsonpath="{.data.$$2}" 2>/dev/null | base64 -d || true; }; \
	PG_ADMIN=$$(getpw data-postgres postgres-password);    [ -n "$$PG_ADMIN" ] || PG_ADMIN=$$(openssl rand -hex 16); \
	PG_AGG=$$(getpw data-postgres aggregator-password);    [ -n "$$PG_AGG" ]   || PG_AGG=$$(openssl rand -hex 16); \
	PG_DPG=$$(getpw data-postgres dpg-password);           [ -n "$$PG_DPG" ]   || PG_DPG=$$(openssl rand -hex 16); \
	REDIS_PW=$$(getpw data-redis redis-password);          [ -n "$$REDIS_PW" ] || REDIS_PW=$$(openssl rand -hex 16); \
	helm upgrade --install $(COMMON_REL) $(COMMON_DIR) \
	  -n $(COMMON_NS) --create-namespace \
	  -f $(COMMON_DIR)/values.yaml \
	  --set credentials.postgresAdminPassword=$$PG_ADMIN \
	  --set credentials.aggregatorPassword=$$PG_AGG \
	  --set credentials.dpgPassword=$$PG_DPG \
	  --set credentials.redisPassword=$$REDIS_PW \
	  --wait --timeout 5m
	kubectl -n $(COMMON_NS) rollout status deploy/$(COMMON_REL)-ingress-nginx-controller --timeout=180s
	kubectl -n $(COMMON_NS) rollout status deploy/$(COMMON_REL)-cert-manager             --timeout=180s
	kubectl get clusterissuer letsencrypt-prod

platform-uninstall:  ## Uninstall platform release (cluster-wide impact)
	helm uninstall $(COMMON_REL) -n $(COMMON_NS) || true
	kubectl delete namespace $(COMMON_NS) --wait=true --timeout=120s || true

# ─── 2) dpg ────────────────────────────────────────────────────────────────
dpg-install: preflight  ## [2/3] Install DPG umbrella (api, ui, notification, match-score) — uses shared common-services DBs
	@set -euo pipefail; \
	getpw() { kubectl -n $(COMMON_NS) get secret "$$1" -o jsonpath="{.data.$$2}" 2>/dev/null | base64 -d || true; }; \
	PG_PW=$$(getpw data-postgres dpg-password); \
	REDIS_PW=$$(getpw data-redis redis-password); \
	[ -n "$$PG_PW" ]    || { echo "ERROR: common-services Secret data-postgres/dpg-password not found — run 'make platform-install' first"; exit 1; }; \
	[ -n "$$REDIS_PW" ] || { echo "ERROR: common-services Secret data-redis/redis-password not found — run 'make platform-install' first";  exit 1; }; \
	PG_PW="$$PG_PW" REDIS_PW="$$REDIS_PW" NAMESPACE=$(DPG_NS) RELEASE=$(DPG_REL) bash $(DPG_DIR)/install.sh install

dpg-cleanup:  ## Destroy DPG release + PVCs + namespace (DESTRUCTIVE)
	NAMESPACE=$(DPG_NS) RELEASE=$(DPG_REL) bash $(DPG_DIR)/install.sh cleanup --yes

# ─── 3) aggregator-dpg ─────────────────────────────────────────────────────
aggregator-install: preflight  ## [3/3] Install aggregator-dpg (web, api, worker, keycloak) — uses shared common-services DBs
	@set -euo pipefail; \
	getpw() { kubectl -n $(COMMON_NS) get secret "$$1" -o jsonpath="{.data.$$2}" 2>/dev/null | base64 -d || true; }; \
	PG_PW=$$(getpw data-postgres aggregator-password); \
	REDIS_PW=$$(getpw data-redis redis-password); \
	[ -n "$$PG_PW" ]    || { echo "ERROR: common-services Secret data-postgres/aggregator-password not found — run 'make platform-install' first"; exit 1; }; \
	[ -n "$$REDIS_PW" ] || { echo "ERROR: common-services Secret data-redis/redis-password not found — run 'make platform-install' first";        exit 1; }; \
	bash $(AGG_DIR)/install.sh -n $(AGG_NS) -r $(AGG_REL) \
	  --set secrets.postgresPassword=$$PG_PW \
	  --set secrets.redisPassword=$$REDIS_PW

aggregator-uninstall:  ## Uninstall aggregator release
	helm uninstall $(AGG_REL) -n $(AGG_NS) || true
	kubectl delete namespace $(AGG_NS) --wait=true --timeout=120s || true

# ─── full stack ────────────────────────────────────────────────────────────
install: platform-install dpg-install aggregator-install  ## Install all 3 in order
	@echo
	@echo "✔ all releases deployed: platform, dpg, aggregator"
	@kubectl get clusterissuer letsencrypt-prod
	@kubectl -n $(DPG_NS) get pods,svc,ingress
	@kubectl -n $(AGG_NS) get pods,svc,ingress

uninstall: aggregator-uninstall dpg-cleanup platform-uninstall  ## Uninstall everything (reverse order)
	@echo "✔ all releases removed"

# ─── static checks ─────────────────────────────────────────────────────────
lint:  ## helm lint all 3 charts
	helm lint $(COMMON_DIR)
	helm lint $(DPG_DIR)
	helm lint $(AGG_DIR)

template:  ## helm template all 3 (rendering smoke test)
	@helm template $(COMMON_REL) $(COMMON_DIR)           >/dev/null && echo "✔ platform renders"
	@helm template $(DPG_REL)      $(DPG_DIR)                >/dev/null && echo "✔ dpg renders"
	@helm template $(AGG_REL)      $(AGG_DIR)                >/dev/null && echo "✔ aggregator-dpg renders"

dry-run: preflight  ## helm --dry-run all 3 against current cluster
	helm upgrade --install $(COMMON_REL) $(COMMON_DIR) -n $(COMMON_NS) --create-namespace --dry-run
	helm upgrade --install $(DPG_REL)      $(DPG_DIR)      -n $(DPG_NS)      --create-namespace --dry-run
	bash $(AGG_DIR)/install.sh -n $(AGG_NS) -r $(AGG_REL) --dry-run

.PHONY: help preflight \
        platform-install platform-uninstall \
        dpg-install dpg-cleanup \
        aggregator-install aggregator-uninstall \
        install uninstall lint template dry-run
