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
MON_VALUES="${MON_VALUES:-$SCRIPT_DIR/monitoring-values.yaml}"

# Namespaces.
CS_NS="${CS_NS:-common-services}"
SIGNALS_NS="${SIGNALS_NS:-signals}"
AGG_NS="${AGG_NS:-aggregator}"
MON_NS="${MON_NS:-monitoring}"

# Helm release names.
CS_REL="${CS_REL:-common-services}"
SIGNALS_REL="${SIGNALS_REL:-signals}"
AGG_REL="${AGG_REL:-aggregator}"
MON_REL="${MON_REL:-monitoring}"

# Chart directories.
CS_DIR="$REPO_ROOT/helm/common-services"
SIGNALS_DIR="$REPO_ROOT/helm/signals"
AGG_DIR="$REPO_ROOT/helm/aggregator"
MON_DIR="$REPO_ROOT/helm/monitoring"

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
    terragrunt run --all apply
}

# Run plan or apply for a single terragrunt module by directory name.
function _plan_tf_module() {
    local module="$1"
    source tf.sh
    echo -e "\nPlanning module: $module"
    ( cd "$module" && terragrunt init && terragrunt plan )
}

function _apply_tf_module() {
    local module="$1"
    source tf.sh
    echo -e "\nApplying module: $module"
    ( cd "$module" && terragrunt init && terragrunt apply )
}

function plan_tf_network()          { _plan_tf_module "network"; }
function plan_tf_eks()              { _plan_tf_module "eks"; }
function plan_tf_iam()              { _plan_tf_module "iam"; }
function plan_tf_storage()          { _plan_tf_module "storage"; }
function plan_tf_random_passwords() { _plan_tf_module "random_passwords"; }
function plan_tf_output_file()      { _plan_tf_module "output-file"; }
function plan_tf_rds()              { _plan_tf_module "rds"; }

function apply_tf_network()          { _apply_tf_module "network"; }
function apply_tf_eks()              { _apply_tf_module "eks"; }
function apply_tf_iam()              { _apply_tf_module "iam"; }
function apply_tf_storage()          { _apply_tf_module "storage"; }
function apply_tf_random_passwords() { _apply_tf_module "random_passwords"; }
function apply_tf_output_file()      { _apply_tf_module "output-file"; }
function apply_tf_rds()              { _apply_tf_module "rds"; }

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

# 2a-pre) monitoring (Prometheus + Alertmanager + Loki + Alloy + Grafana)
# Deployed before app charts so metrics and alerts are live from first deploy.
function deploy_monitoring() {
    echo -e "\nDeploying monitoring"
    helm upgrade --install "$MON_REL" "$MON_DIR" \
        -n "$MON_NS" --create-namespace \
        -f "$MON_VALUES" \
        --wait --timeout 10m
}

# 2a) common-services (ingress-nginx + cert-manager + ClusterIssuer + Postgres + Redis)
# Ensure gp3 is the cluster-default StorageClass first — common-services Postgres
# and Redis provision PVCs that must bind to gp3 (Makefile enforced this as a dep).
function deploy_common_services() {
    apply_gp3_default_sc
    apply_kong_crds
    echo -e "\nDeploying common-services"
    helm upgrade --install "$CS_REL" "$CS_DIR" \
        -n "$CS_NS" --create-namespace \
        -f "$CS_VALUES" \
        --wait --timeout 5m
}

# Kong's CRDs ship inside the vendored subchart (charts/kong/crds/), but Helm
# installs CRDs ONLY from the top-level chart's crds/ dir and ONLY on first
# install — never from a subchart, never on upgrade. So a plain `helm upgrade`
# of an existing release will NOT lay down (or update) the Kong CRDs, and the
# ingress controller then crash-watches missing KongClusterPlugin/KongPlugin
# kinds. Apply them explicitly here (idempotent, server-side) before every
# common-services deploy. Source of truth: helm/common-services/crds/.
function apply_kong_crds() {
    echo -e "\nApplying Kong CRDs (helm skips subchart/upgrade CRDs)"
    kubectl apply --server-side -f "$CS_DIR/crds/"
}

# 2b) signals (api, ui, notification, match-score) — uses shared common-services DBs
function deploy_signals() {
    echo -e "\nDeploying signals"
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" \
        -n "$SIGNALS_NS" --create-namespace \
        -f "$SIGNALS_VALUES" \
        --wait --timeout 10m
}

# 2c) aggregator (web, api, worker, keycloak) — uses shared common-services DBs
function deploy_aggregator() {
    echo -e "\nDeploying aggregator"
    helm upgrade --install "$AGG_REL" "$AGG_DIR" \
        -n "$AGG_NS" --create-namespace \
        -f "$AGG_VALUES" \
        --wait --timeout 10m
}

# ═══ helm: deploy everything ══════════════════════════════════════════════════
# 3) Full stack, in dependency order: namespaces+secrets → common-services →
#    signals → aggregator.
function deploy_all_services() {
    preflight
    create_namespaces_and_secrets
    deploy_monitoring
    deploy_common_services
    deploy_signals
    deploy_aggregator
    fix_acme_issuer_uri
    echo -e "\n✔ all releases deployed: monitoring, common-services, signals, aggregator"
}

# cert-manager v1.20.2 bug (cert-manager/cert-manager#7846): the controller
# never persists status.acme.uri on the ClusterIssuer, which triggers a ~2s
# "Re-checking ACME account registration" loop. Orders/challenges signed during
# that churn fail with "No Key ID in JWS header" / "Account not found" and
# certificates stay READY=False. Until an upstream fix ships (v1.20.2 is the
# latest stable as of 2026-06), recover the account URI from any challenge URL
# (boulder embeds the account id: /acme/chall/<acct>/...) and patch it into the
# issuer status, then clear the poisoned cert chains so they reissue cleanly.
function fix_acme_issuer_uri() {
    local uri server acct chall
    uri=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.status.acme.uri}' 2>/dev/null || true)
    if [ -n "$uri" ]; then
        echo -e "\n✔ ClusterIssuer status.acme.uri already set: $uri"
        return 0
    fi
    echo -e "\nClusterIssuer status.acme.uri blank (cert-manager#7846) — recovering from challenge URL"
    # A challenge only exists once a Certificate kicks off; certs are created by
    # ingress-shim right after the signals/aggregator ingresses land. Poll.
    for _ in $(seq 1 24); do
        chall=$(kubectl get challenge -A -o jsonpath='{.items[0].spec.url}' 2>/dev/null || true)
        [ -n "$chall" ] && break
        sleep 5
    done
    if [ -z "$chall" ]; then
        echo "WARN: no ACME challenge found to recover the account id from." >&2
        echo "      If certificates stay un-ready, patch manually:" >&2
        echo "      kubectl patch clusterissuer letsencrypt-prod --subresource=status --type=merge -p '{\"status\":{\"acme\":{\"uri\":\"<server>/acme/acct/<id>\"}}}'" >&2
        return 0
    fi
    acct=$(echo "$chall" | sed -E 's#.*/acme/chall/([0-9]+)/.*#\1#')
    server=$(kubectl get clusterissuer letsencrypt-prod -o jsonpath='{.spec.acme.server}' | sed 's#/directory$##')
    kubectl patch clusterissuer letsencrypt-prod --subresource=status --type=merge \
        -p "{\"status\":{\"acme\":{\"uri\":\"${server}/acme/acct/${acct}\"}}}"
    echo "✔ patched issuer uri → ${server}/acme/acct/${acct}"
    # Orders/challenges created during the loop are signed with a bad kid and
    # can't recover; delete the whole chain (incl. certs + secrets) so
    # ingress-shim recreates everything against the now-stable account.
    for ns in "$SIGNALS_NS" "$AGG_NS"; do
        kubectl delete order,certificaterequest,challenge,certificate -n "$ns" --all --ignore-not-found 2>/dev/null || true
        kubectl delete secret -n "$ns" --field-selector type=kubernetes.io/tls --ignore-not-found 2>/dev/null || true
    done
    echo "✔ cleared poisoned cert chains; certificates will reissue (watch: kubectl get certificate -A)"
}

# ═══ helm: destroy individual services ════════════════════════════════════════
# 4) Uninstall each release and delete its namespace. Reverse of deploy order.

function destroy_monitoring() {
    echo -e "\nDestroying monitoring"
    helm uninstall "$MON_REL" -n "$MON_NS" || true
    kubectl delete namespace "$MON_NS" --wait=true --timeout=120s || true
}

function destroy_aggregator() {
    echo -e "\nDestroying aggregator"
    helm uninstall "$AGG_REL" -n "$AGG_NS" || true
    kubectl delete namespace "$AGG_NS" --wait=true --timeout=120s || true
}

function destroy_common_services() {
    echo -e "\nDestroying common-services"
    helm uninstall "$CS_REL" -n "$CS_NS" || true
    kubectl delete namespace "$CS_NS" --wait=true --timeout=120s || true
    cleanup_cert_manager_leftovers
}

# cert-manager CRDs carry a "keep" resource policy, so helm uninstall leaves
# them (and every Certificate/Issuer/Order/Challenge CR) behind. The
# ClusterIssuer is a helm hook resource, so it also survives uninstall —
# carrying stale ACME status that bricks the issuer on the next install
# ("no registrations with public key"). Wipe everything cert-manager owns.
function cleanup_cert_manager_leftovers() {
    echo -e "\nCleaning up cert-manager leftovers (CRDs, webhooks, ACME account key)"
    kubectl delete crd \
        challenges.acme.cert-manager.io \
        orders.acme.cert-manager.io \
        certificaterequests.cert-manager.io \
        certificates.cert-manager.io \
        clusterissuers.cert-manager.io \
        issuers.cert-manager.io \
        --ignore-not-found
    kubectl delete validatingwebhookconfiguration,mutatingwebhookconfiguration \
        -l app.kubernetes.io/instance="$CS_REL" --ignore-not-found
    # Stale ACME account key = broken issuer on next install. Namespace deletion
    # above usually removes it, but be explicit in case the namespace survived.
    kubectl delete secret letsencrypt-prod-account-key -n "$CS_NS" --ignore-not-found 2>/dev/null || true
}

function destroy_signals() {
    echo -e "\nDestroying signals"
    helm uninstall "$SIGNALS_REL" -n "$SIGNALS_NS" || true
    kubectl delete namespace "$SIGNALS_NS" --wait=true --timeout=120s || true
}

# ═══ helm: cleanup everything ═════════════════════════════════════════════════
# 5) Tear down all 4 in reverse dependency order.
function cleanup_all_services() {
    destroy_aggregator
    destroy_signals
    destroy_common_services
    destroy_monitoring
    echo -e "\n✔ all releases removed"
}

# ═══ helm: static checks / dev helpers ════════════════════════════════════════

# Verify tooling + cluster reachable + the 3 generated values files exist.
# yq is no longer needed (no slicing) — only helm + kubectl.
function preflight() {
    command -v helm    >/dev/null || { echo "ERROR: helm not installed"    >&2; exit 1; }
    command -v kubectl >/dev/null || { echo "ERROR: kubectl not installed" >&2; exit 1; }
    kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable; check kubeconfig" >&2; exit 1; }
    for f in "$CS_VALUES" "$SIGNALS_VALUES" "$AGG_VALUES" "$MON_VALUES"; do
        test -f "$f" || {
            echo "ERROR: values file not found: $f" >&2
            echo "       Run \`terragrunt run --all apply\` from $SCRIPT_DIR first." >&2
            exit 1
        }
    done
    echo "context : $(kubectl config current-context)"
    echo "values  : $CS_VALUES, $SIGNALS_VALUES, $AGG_VALUES, $MON_VALUES"
}

# helm lint all 4 charts.
function lint() {
    helm lint "$MON_DIR"
    helm lint "$CS_DIR"
    helm lint "$SIGNALS_DIR"
    helm lint "$AGG_DIR"
}

# helm --dry-run all 4 charts against the current cluster (renders + server-side checks,
# installs nothing). Runs preflight first.
function dry_run() {
    preflight
    helm upgrade --install "$MON_REL" "$MON_DIR" -n "$MON_NS" --create-namespace \
        -f "$MON_VALUES" --dry-run
    helm upgrade --install "$CS_REL" "$CS_DIR" -n "$CS_NS" --create-namespace \
        -f "$CS_VALUES" --dry-run
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" -n "$SIGNALS_NS" --create-namespace \
        -f "$SIGNALS_VALUES" --dry-run
    helm upgrade --install "$AGG_REL" "$AGG_DIR" -n "$AGG_NS" --create-namespace \
        -f "$AGG_VALUES" --dry-run
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
