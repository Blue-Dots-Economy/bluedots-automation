#!/bin/bash
set -euo pipefail

environment=$(basename "$(pwd)")

# ─── path discovery ──────────────────────────────────────────────────────────
# install.sh lives at opentofu/azure/<env>/install.sh; repo root is 3 levels up.
# Helm-only: the Azure infrastructure is provisioned by the client, not by this repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Hand-filled from the *.example.yaml files beside this script (gitignored).
GLOBAL_SECRETS="${GLOBAL_SECRETS:-$SCRIPT_DIR/global-secrets.yaml}"
GLOBAL_CLOUD_VALUES="${GLOBAL_CLOUD_VALUES:-$SCRIPT_DIR/global-cloud-values.yaml}"
# Non-sensitive config passed directly to Helm via -f (keys match chart schemas).
GLOBAL_VALUES="${GLOBAL_VALUES:-$SCRIPT_DIR/global-values.yaml}"

# Git ref the network/consent config is fetched from at deploy time from the
# unified schemas repo Blue-Dots-Economy/bluedots-schemas
# (scripts/fetch-configs.sh). Default main; pin to a tag/SHA for prod to avoid
# config/code skew.
SIGNALS_DPG_REF="${SIGNALS_DPG_REF:-main}"
# Ref the aggregator consent doc is fetched from (same schemas repo,
# scripts/fetch-configs.sh aggregator). Default main; pin per env.
AGGREGATOR_DPG_REF="${AGGREGATOR_DPG_REF:-main}"
# Schemas repo the network.json + consent are fetched from. Passed to BOTH
# fetch-configs.sh (which downloads network.json for signals) and the aggregator
# chart (which builds AGGREGATOR_NETWORK_SOURCE from the same repo+ref, since the
# aggregator fetches network.json itself at boot rather than mounting it). Keeping
# one variable for both is what stops the two halves resolving different schemas.
SIGNALS_DPG_REPO="${SIGNALS_DPG_REPO:-Blue-Dots-Economy/bluedots-schemas}"

# ── Image pull credentials ────────────────────────────────────────────────────
# IMAGES_PUBLIC=true (default)  public images; no ghcr-pull Secret is created and
#   the charts reference none. Two keys are cleared, not one: the Bitnami
#   postgresql subchart merges its own image.pullSecrets with the global instead
#   of deferring to it.
# IMAGES_PUBLIC=false           private images; GHCR_PAT is required and the
#   ghcr-pull Secret is written into each namespace.
IMAGES_PUBLIC="${IMAGES_PUBLIC:-true}"

# Namespaces needing the `ghcr-pull` Secret even when IMAGES_PUBLIC=true, for the
# "one private image in an otherwise-public stack" case.
# IMAGES_PUBLIC=false would instead attach the secret to every pod in every
# namespace. Space-separated; empty = no-op. Pair it with a per-chart
# `imagePullSecrets` in <env>/global-values.yaml — the Secret alone does nothing.
PRIVATE_IMAGE_NAMESPACES="${PRIVATE_IMAGE_NAMESPACES:-}"

# ── Storage ───────────────────────────────────────────────────────────────────
# Cluster-default class (apply_default_sc); deploy_monitoring also pins its PVCs to it.
STORAGE_CLASS_TYPE="${STORAGE_CLASS_TYPE:-managed-csi}"

# Extra helm args appended to every app-chart upgrade, AFTER all the -f overlays,
# so they win. This is the hook CI deployments use to override individual image
# tags without editing global-images.yaml:
#   EXTRA_HELM_ARGS="--set api.image.tag=sha-abc1234" bash install.sh deploy_signals
# Anything not named keeps the tag pinned in global-images.yaml, and the override
# lasts only for that run.
#
# The ${VAR:-} default is load-bearing: this script runs under `set -u`, so a
# bare $EXTRA_HELM_ARGS would abort every deploy with "unbound variable".
#
# The key is the SUBCHART ALIAS, not the service name — see helm/*/Chart.yaml.
# Notably aggregator's api is aliased `aggregator-api` so it does not collide
# with signals' `api` in the shared global-images.yaml.
#
# Applied to the four APP charts only — deploy_monitoring is deliberately
# excluded because it takes no -f "$GLOBAL_IMAGES", so it has no pinned tag to
# override. Adding it there would suggest an override that cannot take effect.
#
# In deploy_aggregator this sits AFTER the two --set global.networkSource.*
# flags, so it can override those too; helm takes the last --set for a key.
EXTRA_HELM_ARGS="${EXTRA_HELM_ARGS:-}"

IMAGE_PULL_HELM_ARGS=""
if [[ "$IMAGES_PUBLIC" == "true" ]]; then
    IMAGE_PULL_HELM_ARGS='--set-json global.imagePullSecrets=[] --set-json postgresql.image.pullSecrets=[]'
    # Loud, because `true` is the DEFAULT and these --set-json flags beat any
    # pull-secret value from a -f overlay: exporting GHCR_PAT and expecting private
    # images to work would otherwise fail as ImagePullBackOff with no clue why.
    if [[ -n "${GHCR_PAT:-}" ]]; then
        echo "WARNING: GHCR_PAT is set but IMAGES_PUBLIC=true — the PAT is IGNORED." >&2
        echo "         No ghcr-pull Secret is created and the charts reference none." >&2
        echo "         For private images: export IMAGES_PUBLIC=false" >&2
    fi
fi
# Source of aggregator.config.yaml — INDEPENDENT of the schemas repo above, because
# canonical for that file is the aggregator-dpg config/ tree. All four parts are
# configurable; override any of them to repoint (e.g. at bluedots-schemas once it
# carries the file) with no chart change. Pin AGGREGATOR_CONFIG_REF for prod.
AGGREGATOR_CONFIG_REPO="${AGGREGATOR_CONFIG_REPO:-Blue-Dots-Economy/aggregator-dpg}"
AGGREGATOR_CONFIG_REF="${AGGREGATOR_CONFIG_REF:-main}"
AGGREGATOR_CONFIG_DIR="${AGGREGATOR_CONFIG_DIR-config}"
AGGREGATOR_CONFIG_FILE="${AGGREGATOR_CONFIG_FILE:-aggregator.config.yaml}"
# Source of the aggregator consent doc. Also aggregator-dpg, and separate from the
# config knobs above so the two can be pinned independently: the aggregator consent
# is an {"audiences":…} document, distinct from the schemas repo's signals consent.
AGGREGATOR_CONSENT_REPO="${AGGREGATOR_CONSENT_REPO:-Blue-Dots-Economy/aggregator-dpg}"
AGGREGATOR_CONSENT_REF="${AGGREGATOR_CONSENT_REF:-main}"
AGGREGATOR_CONSENT_DIR="${AGGREGATOR_CONSENT_DIR-config}"

# Namespaces.
CS_NS="${CS_NS:-common-services}"
SIGNALS_NS="${SIGNALS_NS:-signals}"
AGG_NS="${AGG_NS:-aggregator}"
MON_NS="${MON_NS:-monitoring}"
CM_NS="${CM_NS:-campaign-manager}"
# Keycloak is a shared common service: its own RELEASE, but it lives in the
# common-services NAMESPACE (deliberate exception to the dir==ns convention).
KC_NS="${KC_NS:-$CS_NS}"

# Helm release names.
CS_REL="${CS_REL:-common-services}"
SIGNALS_REL="${SIGNALS_REL:-signals}"
AGG_REL="${AGG_REL:-aggregator}"
MON_REL="${MON_REL:-monitoring}"
KC_REL="${KC_REL:-keycloak}"
CM_REL="${CM_REL:-campaign-manager}"

# Chart directories.
CS_DIR="$REPO_ROOT/helm/common-services"
SIGNALS_DIR="$REPO_ROOT/helm/signals"
AGG_DIR="$REPO_ROOT/helm/aggregator"
MON_DIR="$REPO_ROOT/helm/monitoring"
KC_DIR="$REPO_ROOT/helm/keycloak"
CM_DIR="$REPO_ROOT/helm/campaign-manager"

# Resource overrides (replica counts, HPA, PDB, container resources) — shared across environments.
# Edit helm/global-resources.yaml to change settings across all environments.
GLOBAL_RESOURCES="$REPO_ROOT/helm/global-resources.yaml"

# Image overrides (repository, tag, pullPolicy) — lives per-environment so each
# deployment can pin its own image tags independently.
# Edit opentofu/azure/<env>/global-images.yaml to change image tags for this environment.
GLOBAL_IMAGES="${GLOBAL_IMAGES:-$SCRIPT_DIR/global-images.yaml}"

# ═══ cluster: default StorageClass ════════════════════════════════════════════
# Make $STORAGE_CLASS_TYPE the cluster-default StorageClass (redis/postgres PVCs name
# no class). Adopts an existing class; creates managed-csi only if the Azure Disk CSI driver is present.
function apply_default_sc() {
    local sc="$STORAGE_CLASS_TYPE"

    if kubectl get sc "$sc" >/dev/null 2>&1; then
        echo -e "\nStorageClass \"$sc\" already exists -- marking it default (definition left untouched)"
    elif [[ "$sc" == "managed-csi" ]] && kubectl get csidriver disk.csi.azure.com >/dev/null 2>&1; then
        echo -e "\nCreating Azure Disk StorageClass managed-csi"
        kubectl apply -f "$SCRIPT_DIR/managed-csi-sc.yaml"
    else
        echo "ERROR: StorageClass \"$sc\" (STORAGE_CLASS_TYPE) does not exist." >&2
        echo "       Only managed-csi can be created here, and only when the Azure Disk CSI driver" >&2
        echo "       (disk.csi.azure.com) is installed. List existing classes: kubectl get sc" >&2
        return 1
    fi

    kubectl patch storageclass "$sc" \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    # Demote every OTHER class still claiming default -- two defaults is an error
    # state in which the apiserver picks arbitrarily.
    local other
    for other in $(kubectl get sc \
        -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        [[ "$other" == "$sc" ]] && continue
        echo "Demoting previous default StorageClass \"$other\""
        kubectl patch storageclass "$other" \
            -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    done
}

# ═══ helm: namespaces + image-pull secret ═════════════════════════════════════
# Create the 3 namespaces (common-services, signals, aggregator) if missing.
function create_namespaces() {
    echo -e "\nCreating namespaces: $CS_NS $SIGNALS_NS $AGG_NS"
    for ns in "$CS_NS" "$SIGNALS_NS" "$AGG_NS"; do
        kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"
    done
}

# Optional; create_campaign_manager_image_pull_secret calls it.
function create_campaign_manager_namespace() {
    echo -e "\nCreating namespace: $CM_NS"
    kubectl get ns "$CM_NS" >/dev/null 2>&1 || kubectl create ns "$CM_NS"
}

# Write/refresh the `ghcr-pull` docker-registry Secret in each namespace.
# No-op when IMAGES_PUBLIC=true. Never deletes an existing Secret.
#
# Usage:
#   GHCR_USER=<github-user> GHCR_PAT=ghp_xxx bash install.sh create_image_pull_secret
#   bash install.sh create_image_pull_secret                    # interactive prompt
function create_image_pull_secret() {
    if [[ "$IMAGES_PUBLIC" == "true" ]]; then
        echo -e "\nIMAGES_PUBLIC=true — skipping the ghcr-pull secret (images are public)."
        return 0
    fi

    echo -e "\nCreating ghcr-pull secret in each namespace"
    test -f "$SCRIPT_DIR/rotate-ghcr-pull.sh" || {
        echo "ERROR: $SCRIPT_DIR/rotate-ghcr-pull.sh missing"
        exit 1
    }
    bash "$SCRIPT_DIR/rotate-ghcr-pull.sh" "${GHCR_PAT:-}" "$CS_NS" "$SIGNALS_NS" "$AGG_NS"
}

# Write `ghcr-pull` into ONLY $PRIVATE_IMAGE_NAMESPACES. Deliberately ignores
# IMAGES_PUBLIC — that is the point: the global stays `true` so no other chart
# references a pull secret.
#
#   PRIVATE_IMAGE_NAMESPACES=signals GHCR_PAT=ghp_xxx \
#       bash install.sh create_private_image_pull_secret
function create_private_image_pull_secret() {
    if [[ -z "$PRIVATE_IMAGE_NAMESPACES" ]]; then
        echo -e "\nPRIVATE_IMAGE_NAMESPACES is empty — nothing to do."
        echo "  Set it to the namespace(s) whose pods pull a PRIVATE image, e.g."
        echo "    PRIVATE_IMAGE_NAMESPACES=\"$SIGNALS_NS\" bash install.sh create_private_image_pull_secret"
        return 0
    fi

    echo -e "\nCreating ghcr-pull secret in: $PRIVATE_IMAGE_NAMESPACES"
    test -f "$SCRIPT_DIR/rotate-ghcr-pull.sh" || {
        echo "ERROR: $SCRIPT_DIR/rotate-ghcr-pull.sh missing"
        exit 1
    }
    # Unquoted on purpose: the namespace list is space-separated and must word-split.
    # shellcheck disable=SC2086
    bash "$SCRIPT_DIR/rotate-ghcr-pull.sh" "${GHCR_PAT:-}" $PRIVATE_IMAGE_NAMESPACES

    echo "Reminder: the pod must also REFERENCE it — set the chart's own"
    echo "  imagePullSecrets in <env>/global-values.yaml, or it pulls anonymously."
}

# Write `ghcr-pull` into the campaign-manager namespace (created if missing).
#   GHCR_PAT=ghp_xxx bash install.sh create_campaign_manager_image_pull_secret
function create_campaign_manager_image_pull_secret() {
    create_campaign_manager_namespace
    echo -e "\nCreating ghcr-pull secret in: $CM_NS"
    test -f "$SCRIPT_DIR/rotate-ghcr-pull.sh" || {
        echo "ERROR: $SCRIPT_DIR/rotate-ghcr-pull.sh missing"
        exit 1
    }
    bash "$SCRIPT_DIR/rotate-ghcr-pull.sh" "${GHCR_PAT:-}" "$CM_NS"
    echo "Set <subchart>.imagePullSecret.private: true for each private campaign-manager image."
}

# Both, in order. Kept because deploy_all_services and the runbooks call it.
# The third is a no-op unless PRIVATE_IMAGE_NAMESPACES is set.
function create_namespaces_and_secrets() {
    create_namespaces
    create_image_pull_secret
    create_private_image_pull_secret
}

# ═══ helm: deploy individual services ═════════════════════════════════════════
# Each helm upgrade layers the chart's own values.yaml first, then the
# hand-filled per-env overlays (-f order = precedence). The overlay
# already holds values at root level, so it feeds helm directly — no slicing.

# Monitoring's PVCs name their class explicitly instead of inheriting the
# cluster default the way postgres/redis do. That is not a preference: these
# four were ALREADY deployed with the name written into their StatefulSet
# volumeClaimTemplates and Grafana's PVC, and both are immutable, so a render
# that omits it is rejected on every existing cluster.
#
# Set here rather than in the chart so the value stays platform-neutral, and
# one path at a time because kube-prometheus-stack and loki expose no global
# storage key. These four are the whole set: jaeger and otelcollector are
# disabled, and alloy is a DaemonSet (it has a PVC only in statefulset mode).
#
# A FUNCTION, not inlined in deploy_monitoring, so dry_run's separate `helm
# upgrade --dry-run` for monitoring (below) renders the SAME flags rather than
# silently validating a manifest with no storageClassName on any of the four.
function _monitoring_sc_args() {
    local args="" p
    for p in prometheus.grafana.persistence.storageClassName \
             prometheus.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName \
             prometheus.alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName \
             loki.singleBinary.persistence.storageClass; do
        args+=" --set $p=$STORAGE_CLASS_TYPE"
    done
    echo "$args"
}

# 2a-pre) monitoring (Prometheus + Alertmanager + Loki + Alloy + Grafana)
# Deployed before app charts so metrics and alerts are live from first deploy.
function deploy_monitoring() {
    apply_prometheus_crds
    local sc_args
    sc_args="$(_monitoring_sc_args)"

    echo -e "\nDeploying monitoring"
    helm upgrade --install "$MON_REL" "$MON_DIR" \
        -n "$MON_NS" --create-namespace \
        -f "$GLOBAL_VALUES" \
        -f "$GLOBAL_SECRETS" \
        $IMAGE_PULL_HELM_ARGS \
        $sc_args \
        --wait --timeout 10m
}

# Same Helm limitation as Kong (see apply_kong_crds below): CRDs vendored inside
# a subchart (kube-prometheus-stack's charts/crds/) are laid down by Helm ONLY
# on first install, never on upgrade. Bumping kube-prometheus-stack across a
# CRD-bearing version (e.g. 65.1.1 -> 88.5.2, operator 0.77.1 -> 0.93.1) then
# leaves an existing cluster's CRDs behind: the apiserver silently PRUNES any
# field the old CRD schema doesn't know about on a structural CRD, with no
# error — pods stay Ready, new spec fields just don't take effect.
#
# The chart's own opt-in remedy (`crds.upgradeJob.enabled`) is marked preview
# upstream; applying the manifests directly, same as Kong, avoids taking a
# dependency on that. MUST be --server-side: a plain `kubectl apply` writes a
# client-side last-applied-configuration annotation capped at 256 KB, and
# crd-prometheuses.yaml / crd-alertmanagers.yaml alone are 833 KB / 621 KB.
#
# NOT vendored as a committed helm/monitoring/crds/ directory the way Kong's
# is: Helm bundles a chart's own top-level crds/ into the packaged Chart
# object, which is what gets stored (gzipped) in the release Secret — kube-
# prometheus-stack's ~4.3 MB of CRDs pushed that Secret past etcd's 1 MiB
# object limit on the very first upgrade attempt (`Too long: may not be more
# than 1048576 bytes`). Extracted straight out of the already-vendored
# charts/kube-prometheus-stack-*.tgz into a throwaway tempdir instead, so
# nothing new is committed and nothing new is bundled into the release.
function apply_prometheus_crds() {
    echo -e "\nApplying prometheus-operator CRDs (helm skips subchart/upgrade CRDs)"
    local tgz tmp
    tgz=$(ls "$MON_DIR"/charts/kube-prometheus-stack-*.tgz 2>/dev/null | head -1)
    if [ -z "$tgz" ]; then
        echo "ERROR: no kube-prometheus-stack-*.tgz found under $MON_DIR/charts/" >&2
        return 1
    fi
    tmp=$(mktemp -d)
    tar -xzf "$tgz" -C "$tmp" kube-prometheus-stack/charts/crds/crds/
    kubectl apply --server-side -f "$tmp/kube-prometheus-stack/charts/crds/crds/"
    rm -rf "$tmp"
}

# 2a) common-services (Kong + cert-manager + ClusterIssuer + Postgres + Redis)
# Postgres and Redis name no StorageClass of their own, so their PVCs bind to the
# cluster default. Set it once with `bash install.sh apply_default_sc` before the
# first deploy_common_services.
function deploy_common_services() {
    apply_kong_crds
    echo -e "\nDeploying common-services"
    helm upgrade --install "$CS_REL" "$CS_DIR" \
        -n "$CS_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" \
        -f "$GLOBAL_IMAGES" \
        -f "$GLOBAL_VALUES" \
        -f "$GLOBAL_CLOUD_VALUES" \
        -f "$GLOBAL_SECRETS" \
        $IMAGE_PULL_HELM_ARGS \
        $EXTRA_HELM_ARGS \
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
# Fetch the served network's network.json + consent.json from the unified schemas
# repo bluedots-schemas (driven by _network/_brand in
# global-values.yaml) into the chart's files/ dir, where schemas-configmap.yaml
# renders them into the -schemas ConfigMap. Fetched fresh each deploy; not
# committed → can't drift.
function fetch_signals_configs() {
    bash "$REPO_ROOT/scripts/fetch-configs.sh" signals \
        --global-values "$GLOBAL_VALUES" \
        --repo "$SIGNALS_DPG_REPO" \
        --ref "$SIGNALS_DPG_REF"
}

# Fetch the aggregator consent (FULL doc, brand>network fallback) from the unified
# schemas repo bluedots-schemas into
# helm/aggregator/files/consent/consent.json, where consent-configmap.yaml renders
# it into the {release}-consent ConfigMap. Fetched fresh each deploy; not
# committed → can't drift.
function fetch_aggregator_configs() {
    bash "$REPO_ROOT/scripts/fetch-configs.sh" aggregator \
        --global-values "$GLOBAL_VALUES" \
        --ref "$AGGREGATOR_DPG_REF" \
        --config-repo "$AGGREGATOR_CONFIG_REPO" \
        --config-ref "$AGGREGATOR_CONFIG_REF" \
        --config-dir "$AGGREGATOR_CONFIG_DIR" \
        --config-file "$AGGREGATOR_CONFIG_FILE" \
        --consent-repo "$AGGREGATOR_CONSENT_REPO" \
        --consent-ref "$AGGREGATOR_CONSENT_REF" \
        --consent-dir "$AGGREGATOR_CONSENT_DIR"
}

# Shared Keycloak — its OWN release, in the common-services namespace.
#
# WHY A SEPARATE RELEASE and not a subchart of common-services: the `keycloak`
# database is created by common-services' postgres-bootstrap-job, which is a
# post-install HOOK (weight 0). Helm with --wait installs main resources, waits
# for them to be Ready, and only THEN runs post-install hooks. A Keycloak
# Deployment inside that release would crash-loop on the missing database while
# the hook that creates it never runs — the release deadlocks and times out.
# Keeping it a later release means the database already exists by the time
# Keycloak starts. Do not "simplify" this back into common-services.
#
# Must run AFTER deploy_common_services and BEFORE deploy_signals: signals' api
# asserts its Keycloak config at boot once AUTH_PROVIDER=keycloak.
function deploy_keycloak() {
    echo -e "\nDeploying keycloak (shared realm, both DPGs) into $KC_NS"
    helm upgrade --install "$KC_REL" "$KC_DIR" \
        -n "$KC_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" \
        -f "$GLOBAL_IMAGES" \
        -f "$GLOBAL_VALUES" \
        -f "$GLOBAL_CLOUD_VALUES" \
        -f "$GLOBAL_SECRETS" \
        $IMAGE_PULL_HELM_ARGS \
        $EXTRA_HELM_ARGS \
        --wait --timeout 10m
}

function deploy_signals() {
    echo -e "\nDeploying signals"
    fetch_signals_configs
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" \
        -n "$SIGNALS_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" \
        -f "$GLOBAL_IMAGES" \
        -f "$GLOBAL_VALUES" \
        -f "$GLOBAL_CLOUD_VALUES" \
        -f "$GLOBAL_SECRETS" \
        $IMAGE_PULL_HELM_ARGS \
        $EXTRA_HELM_ARGS \
        --wait --timeout 10m
}

# 2c) aggregator (web, api, worker, keycloak) — uses shared common-services DBs
function deploy_aggregator() {
    echo -e "\nDeploying aggregator"
    fetch_aggregator_configs
    # networkSource repo/ref passed here rather than pinned in global-values.yaml, so
    # the aggregator's network.json URL is built from the same repo+ref
    # fetch-configs.sh used for signals — one pin covers both halves.
    helm upgrade --install "$AGG_REL" "$AGG_DIR" \
        -n "$AGG_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" \
        -f "$GLOBAL_IMAGES" \
        -f "$GLOBAL_VALUES" \
        -f "$GLOBAL_CLOUD_VALUES" \
        -f "$GLOBAL_SECRETS" \
        $IMAGE_PULL_HELM_ARGS \
        --set "global.networkSource.repo=$SIGNALS_DPG_REPO" \
        --set "global.networkSource.ref=$SIGNALS_DPG_REF" \
        $EXTRA_HELM_ARGS \
        --wait --timeout 10m
    # subPath mounts don't hot-update and the config is boot-cached in-process, so a
    # config-only change leaves the Deployment spec untouched and helm rolls nothing.
    restart_aggregator_config_consumers
}

# Roll the workloads that subPath-mount the {release}-network-config /
# {release}-consent ConfigMaps, so a config-only change takes effect. Safe to re-run.
#
# Non-fatal by design: this runs under `set -euo pipefail` as the last statement in
# deploy_aggregator, so propagating a slow rollout would abort deploy_all_services
# and skip the steps after it (fix_acme_issuer_uri). Failures warn and return 0.
function restart_aggregator_config_consumers() {
    local dep failed=""
    echo "Restarting aggregator config consumers (subPath mounts don't hot-update)"
    for dep in "$AGG_REL-api" "$AGG_REL-worker" "$AGG_REL-web"; do
        if ! kubectl -n "$AGG_NS" get deploy "$dep" >/dev/null 2>&1; then
            echo "  (skip: deploy/$dep not found in $AGG_NS)"
            continue
        fi
        if ! kubectl -n "$AGG_NS" rollout restart "deploy/$dep"; then
            echo "  ⚠ could not restart deploy/$dep" >&2
            failed="$failed $dep"
            continue
        fi
        if ! kubectl -n "$AGG_NS" rollout status "deploy/$dep" --timeout=5m; then
            echo "  ⚠ deploy/$dep not Ready within 5m" >&2
            failed="$failed $dep"
        fi
    done
    if [ -n "$failed" ]; then
        echo "  ⚠ config restart incomplete for:${failed}" >&2
        echo "    The helm release is applied, but these pods may still be serving the" >&2
        echo "    PREVIOUS aggregator.config.yaml / consent. Investigate with:" >&2
        echo "      kubectl -n $AGG_NS get pods" >&2
        echo "      kubectl -n $AGG_NS logs deploy/<name> --tail=100" >&2
        echo "    then re-run: bash install.sh restart_aggregator_config_consumers" >&2
    fi
    return 0
}

# Renders nothing unless _campaign_manager_enabled / its sync toggles are on.
function deploy_campaign_manager() {
    echo -e "\nDeploying campaign-manager"
    helm upgrade --install "$CM_REL" "$CM_DIR" \
        -n "$CM_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" \
        -f "$GLOBAL_IMAGES" \
        -f "$GLOBAL_VALUES" \
        -f "$GLOBAL_CLOUD_VALUES" \
        -f "$GLOBAL_SECRETS" \
        $IMAGE_PULL_HELM_ARGS \
        $EXTRA_HELM_ARGS \
        --wait --timeout 10m
}

# ═══ helm: deploy everything ══════════════════════════════════════════════════
# 3) Full stack, in dependency order: namespaces+secrets → common-services →
#    signals → aggregator → campaign-manager.
function deploy_all_services() {
    preflight
    create_namespaces_and_secrets
    deploy_monitoring
    deploy_common_services
    deploy_keycloak
    deploy_signals
    deploy_aggregator
    deploy_campaign_manager
    fix_acme_issuer_uri
    echo -e "\n✔ all releases deployed: monitoring, common-services, keycloak, signals, aggregator, campaign-manager"
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

# Remove ONLY the keycloak release. It shares the common-services namespace, so
# this must NOT delete the namespace — that would take Postgres/Redis/Kong with it.
#
# DANGER: uninstalling Keycloak does not drop the `keycloak` database, so users
# survive a re-install. Deleting the common-services NAMESPACE does destroy it,
# and that now wipes identity for BOTH DPGs, not just the aggregator.
function destroy_keycloak() {
    echo -e "\nDestroying keycloak (release only — namespace $KC_NS is left intact)"
    helm uninstall "$KC_REL" -n "$KC_NS" || true
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
    destroy_keycloak
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
    for f in "$GLOBAL_SECRETS" "$GLOBAL_CLOUD_VALUES"; do
        test -f "$f" || {
            echo "ERROR: values file not found: $f" >&2
            echo "       Copy $(basename "$f" .yaml).example.yaml to $(basename "$f") and fill it in" >&2
            echo "       (generate-passwords.sh fills the random passwords in global-secrets.yaml)." >&2
            exit 1
        }
    done
    echo "context : $(kubectl config current-context)"
    echo "secrets : $GLOBAL_SECRETS"
    echo "cloud   : $GLOBAL_CLOUD_VALUES"
    echo "config  : $GLOBAL_VALUES (user-edited non-secret config)"
}

# helm lint all 6 charts.
function lint() {
    helm lint "$MON_DIR"
    helm lint "$CS_DIR"
    helm lint "$SIGNALS_DIR"
    # Keycloak guards its secrets the same way the aggregator does, AND requires a
    # realm name with no literal default (the realm is per-instance). Static
    # renders have neither, so supply both.
    helm lint "$KC_DIR" --set global.existingSecret=lint-only --set global.keycloakRealm=lint-only
    # Realm content invariants — no localhost redirects, no test users, org_owner
    # present, all 7 clients, gate scoped to the portal. See scripts/assert-realm.sh.
    bash "$REPO_ROOT/scripts/assert-realm.sh"
    # Shell invariants that `bash -n` cannot see — currently a commented-out flag
    # parked inside a `\`-continued command, which silently truncates that command's
    # arguments. Checks the shared scripts AND this env's own install.sh.
    bash "$REPO_ROOT/scripts/assert-shell.sh"
    # Aggregator secrets are guarded (aggregator.requireSecret fails the render on
    # empty / `change-me` placeholders). A bare `helm lint` has no real creds, so
    # point it at a placeholder existingSecret to skip the secret block — a real
    # deploy still validates its actual values from global-secrets.yaml.
    # NOTE: no networkConfigDelivery override needed here. The network-config
    # template's `fail` fires when the fetched aggregator.config.yaml is absent, but
    # `helm lint` only logs it as [INFO] and still exits 0 — unlike `helm template`,
    # which errors (hence the flag in .github/workflows/ci.yml's template step).
    helm lint "$AGG_DIR" --set global.existingSecret=lint-only
    # Dummies for the chart's required values so lint runs without creds.
    helm lint "$CM_DIR" \
        --set global.enabled=true \
        --set global.database.host=lint-only --set global.database.password=lint-only \
        --set app.database.admin.password=lint-only \
        --set app.secrets.SESSION_SECRET=lint-only --set app.secrets.CRON_SECRET=lint-only
}

# helm --dry-run all 6 charts against the current cluster (renders + server-side checks,
# installs nothing). Runs preflight first.
function dry_run() {
    preflight
    fetch_signals_configs
    fetch_aggregator_configs
    local mon_sc_args
    mon_sc_args="$(_monitoring_sc_args)"
    helm upgrade --install "$MON_REL" "$MON_DIR" -n "$MON_NS" --create-namespace \
        -f "$GLOBAL_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $mon_sc_args --dry-run
    helm upgrade --install "$CS_REL" "$CS_DIR" -n "$CS_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" -f "$GLOBAL_IMAGES" -f "$GLOBAL_CLOUD_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $EXTRA_HELM_ARGS --dry-run
    helm upgrade --install "$KC_REL" "$KC_DIR" -n "$KC_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" -f "$GLOBAL_IMAGES" -f "$GLOBAL_VALUES" -f "$GLOBAL_CLOUD_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $EXTRA_HELM_ARGS --dry-run
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" -n "$SIGNALS_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" -f "$GLOBAL_IMAGES" -f "$GLOBAL_VALUES" -f "$GLOBAL_CLOUD_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $EXTRA_HELM_ARGS --dry-run
    helm upgrade --install "$AGG_REL" "$AGG_DIR" -n "$AGG_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" -f "$GLOBAL_IMAGES" -f "$GLOBAL_VALUES" -f "$GLOBAL_CLOUD_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $EXTRA_HELM_ARGS --dry-run
    helm upgrade --install "$CM_REL" "$CM_DIR" -n "$CM_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" -f "$GLOBAL_IMAGES" -f "$GLOBAL_VALUES" -f "$GLOBAL_CLOUD_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $EXTRA_HELM_ARGS --dry-run
}

# helm --dry-run ONLY signals, with the same -f layering as deploy_signals.
# Installs nothing. Two reasons this exists next to `dry_run`:
#   - CI can only `helm lint` signals (its `helm template` needs the network
#     schemas fetch_signals_configs pulls at deploy time), so a full render of
#     this chart is never validated automatically — only here.
#   - `dry_run` walks all 6 charts and stops at the first failure, so an
#     unrelated break in monitoring/common-services hides signals entirely.
# Unlike `lint`, this loads the env values files, so it catches YAML anchor and
# values-layering breakage that lint cannot see.
function dry_run_signals() {
    preflight
    fetch_signals_configs
    helm upgrade --install "$SIGNALS_REL" "$SIGNALS_DIR" -n "$SIGNALS_NS" --create-namespace \
        -f "$GLOBAL_RESOURCES" -f "$GLOBAL_IMAGES" -f "$GLOBAL_VALUES" -f "$GLOBAL_CLOUD_VALUES" -f "$GLOBAL_SECRETS" $IMAGE_PULL_HELM_ARGS $EXTRA_HELM_ARGS --dry-run
}

# ─── dispatcher ──────────────────────────────────────────────────────────────
function invoke_functions() {
    for func in "$@"; do
        $func
    done
}

if [ $# -eq 0 ]; then
    echo "Usage: bash install.sh <function> [<function> ...]" >&2
    echo "e.g.   bash install.sh preflight apply_default_sc deploy_common_services" >&2
    exit 1
else
    invoke_functions "$@"
fi
