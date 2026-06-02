#!/bin/bash
set -euo pipefail

environment=$(basename "$(pwd)")

# ─── path discovery ──────────────────────────────────────────────────────────
# install.sh lives at opentofu/aws/<env>/install.sh; repo root is 3 levels up.
# All helm paths derive from here, so copying template/ → dev/ needs no edits.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Per-chart values files produced by opentofu (modules/output-file). Each holds
# its chart's overrides at ROOT level, so a single `-f` feeds helm directly —
# no slicing/yq projection needed.
CS_VALUES="${CS_VALUES:-$SCRIPT_DIR/common-services-values.yaml}"
SIGNALS_VALUES="${SIGNALS_VALUES:-$SCRIPT_DIR/signals-values.yaml}"
AGG_VALUES="${AGG_VALUES:-$SCRIPT_DIR/aggregator-values.yaml}"

# Namespaces.
CS_NS="${CS_NS:-common-services}"
SIGNALS_NS="${SIGNALS_NS:-signals}"
AGG_NS="${AGG_NS:-aggregator}"

# Helm release names.
CS_REL="${CS_REL:-common-services}"
SIGNALS_REL="${SIGNALS_REL:-signals}"
AGG_REL="${AGG_REL:-aggregator}"

# Chart directories.
CS_DIR="$REPO_ROOT/helm/common-services"
SIGNALS_DIR="$REPO_ROOT/helm/signals"
AGG_DIR="$REPO_ROOT/helm/aggregator"

# ═══ terraform / cluster bootstrap ════════════════════════════════════════════

function create_tf_backend() {
    echo -e "Creating terraform state backend"
    bash create_tf_backend.sh
}

function backup_configs() {
    timestamp=$(date +%d%m%y_%H%M%S)
    echo -e "\nBackup existing kubeconfig if it exists"
    mkdir -p ~/.kube
    mv ~/.kube/config ~/.kube/config.$timestamp || true
    export KUBECONFIG=~/.kube/config
}

function plan_tf_resources() {
    source tf.sh
    echo -e "\nPlanning resources on AWS"
    terragrunt run --all init
    terragrunt run --all plan
}

function create_tf_resources() {
    source tf.sh
    echo -e "\nCreating resources on AWS"
    terragrunt run --all init
    terragrunt run --all apply
}

function apply_gp3_default_sc() {
    echo -e "\nApplying gp3 StorageClass as cluster default"
    kubectl apply -f "$SCRIPT_DIR/gp3-sc.yaml"
    # Strip default annotation from gp2 if present, so only gp3 is default
    if kubectl get sc gp2 >/dev/null 2>&1; then
        kubectl patch storageclass gp2 \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    fi
}

function destroy_tf_resources() {
    source tf.sh
    echo -e "Destroying resources on AWS cloud"
    terragrunt run --all destroy
}

# ═══ helm: namespaces + image-pull secret ═════════════════════════════════════
# 1) Create the 3 namespaces (common-services, signals, aggregator) if missing,
#    then write/refresh the `ghcr-pull` docker-registry Secret in each via
#    rotate-ghcr-pull.sh.
#
# Usage:
#   GHCR_PAT=ghp_xxx bash install.sh create_namespaces_and_secrets   # PAT via env
#   bash install.sh create_namespaces_and_secrets                    # interactive prompt
function create_namespaces_and_secrets() {
    echo -e "\nCreating namespaces: $CS_NS $SIGNALS_NS $AGG_NS"
    for ns in "$CS_NS" "$SIGNALS_NS" "$AGG_NS"; do
        kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
    done

    echo -e "\nCreating ghcr-pull secret in each namespace"
    test -f "$SCRIPT_DIR/rotate-ghcr-pull.sh" || {
        echo "ERROR: $SCRIPT_DIR/rotate-ghcr-pull.sh missing"
        exit 1
    }
    bash "$SCRIPT_DIR/rotate-ghcr-pull.sh" "${GHCR_PAT:-}" "$CS_NS" "$SIGNALS_NS" "$AGG_NS"
}

# ═══ helm: deploy individual services ═════════════════════════════════════════
# Each helm upgrade layers the chart's own values.yaml first, then the
# opentofu-generated per-chart overlay (-f order = precedence). The overlay
# already holds values at root level, so it feeds helm directly — no slicing.

# 2a) common-services (ingress-nginx + cert-manager + ClusterIssuer + Postgres + Redis)
# Ensure gp3 is the cluster-default StorageClass first — common-services Postgres
# and Redis provision PVCs that must bind to gp3 (Makefile enforced this as a dep).
function deploy_common_services() {
    apply_gp3_default_sc
    echo -e "\nDeploying common-services"
    helm upgrade --install "$CS_REL" "$CS_DIR" \
        -n "$CS_NS" --create-namespace \
        -f "$CS_DIR/values.yaml" \
        -f "$CS_VALUES" \
        --wait --timeout 5m
}

# 2b) signals (api, ui, notification, match-score) — uses shared common-services DBs
function deploy_signals() {
    echo -e "\nDeploying signals"
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" \
        -n "$SIGNALS_NS" --create-namespace \
        -f "$SIGNALS_DIR/values.yaml" \
        -f "$SIGNALS_VALUES" \
        --wait --timeout 10m
}

# 2c) aggregator (web, api, worker, keycloak) — uses shared common-services DBs
function deploy_aggregator() {
    echo -e "\nDeploying aggregator"
    helm upgrade --install "$AGG_REL" "$AGG_DIR" \
        -n "$AGG_NS" --create-namespace \
        -f "$AGG_DIR/values.yaml" \
        -f "$AGG_VALUES" \
        --wait --timeout 10m
}

# ═══ helm: deploy everything ══════════════════════════════════════════════════
# 3) Full stack, in dependency order: namespaces+secrets → common-services →
#    signals → aggregator.
function deploy_all_services() {
    preflight
    create_namespaces_and_secrets
    deploy_common_services
    deploy_signals
    deploy_aggregator
    echo -e "\n✔ all releases deployed: common-services, signals, aggregator"
}

# ═══ helm: destroy individual services ════════════════════════════════════════
# 4) Uninstall each release and delete its namespace. Reverse of deploy order.

function destroy_aggregator() {
    echo -e "\nDestroying aggregator"
    helm uninstall "$AGG_REL" -n "$AGG_NS" || true
    kubectl delete namespace "$AGG_NS" --wait=true --timeout=120s || true
}

function destroy_common_services() {
    echo -e "\nDestroying common-services"
    helm uninstall "$CS_REL" -n "$CS_NS" || true
    kubectl delete namespace "$CS_NS" --wait=true --timeout=120s || true
}

function destroy_signals() {
    echo -e "\nDestroying signals"
    helm uninstall "$SIGNALS_REL" -n "$SIGNALS_NS" || true
    kubectl delete namespace "$SIGNALS_NS" --wait=true --timeout=120s || true
}

# ═══ helm: cleanup everything ═════════════════════════════════════════════════
# 5) Tear down all 3 in reverse dependency order.
function cleanup_all_services() {
    destroy_aggregator
    destroy_signals
    destroy_common_services
    echo -e "\n✔ all releases removed"
}

# ═══ helm: static checks / dev helpers ════════════════════════════════════════

# Verify tooling + cluster reachable + the 3 generated values files exist.
# yq is no longer needed (no slicing) — only helm + kubectl.
function preflight() {
    command -v helm    >/dev/null || { echo "ERROR: helm not installed"    >&2; exit 1; }
    command -v kubectl >/dev/null || { echo "ERROR: kubectl not installed" >&2; exit 1; }
    kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable; check kubeconfig" >&2; exit 1; }
    for f in "$CS_VALUES" "$SIGNALS_VALUES" "$AGG_VALUES"; do
        test -f "$f" || {
            echo "ERROR: values file not found: $f" >&2
            echo "       Run \`terragrunt run --all apply\` from $SCRIPT_DIR first." >&2
            exit 1
        }
    done
    echo "context : $(kubectl config current-context)"
    echo "values  : $CS_VALUES, $SIGNALS_VALUES, $AGG_VALUES"
}

# helm lint all 3 charts.
function lint() {
    helm lint "$CS_DIR"
    helm lint "$SIGNALS_DIR"
    helm lint "$AGG_DIR"
}

# helm --dry-run all 3 against the current cluster (renders + server-side checks,
# installs nothing). Runs preflight first.
function dry_run() {
    preflight
    helm upgrade --install "$CS_REL" "$CS_DIR" -n "$CS_NS" --create-namespace \
        -f "$CS_DIR/values.yaml" -f "$CS_VALUES" --dry-run
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" -n "$SIGNALS_NS" --create-namespace \
        -f "$SIGNALS_DIR/values.yaml" -f "$SIGNALS_VALUES" --dry-run
    helm upgrade --install "$AGG_REL" "$AGG_DIR" -n "$AGG_NS" --create-namespace \
        -f "$AGG_DIR/values.yaml" -f "$AGG_VALUES" --dry-run
}

# ─── dispatcher ──────────────────────────────────────────────────────────────
function invoke_functions() {
    for func in "$@"; do
        $func
    done
}

if [ $# -eq 0 ]; then
    echo -e "\nPlease ensure you have updated all the mandatory variables as mentioned in the documentation."
    echo "The installation will fail if any of the mandatory variables are missing."
    echo "Press Enter to continue..."
    read -r
    create_tf_backend
    # backup_configs
    create_tf_resources
    apply_gp3_default_sc
else
    invoke_functions "$@"
fi
