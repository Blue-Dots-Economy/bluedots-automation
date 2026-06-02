#!/usr/bin/env bash
# Deploy aggregator-dpg umbrella chart into an existing Kubernetes cluster.
#
# Usage:
#   helm/aggregator-dpg/deploy.sh -n <namespace> [-r <release>] [-f <extra-values>] \
#                                 [-R <image-registry>] [-t <image-tag>] [--dry-run]
#
# Defaults: chart values.yaml is used as-is (no overlay). Pass extra `-f` to
# layer environment-specific overrides on top.
#
# Example:
#   helm/aggregator-dpg/deploy.sh -n aggregator -r aggregator \
#                                 -R ghcr.io/sanketika-labs -t 0.1.0
#
# Pre-reqs in your shell: kubectl, helm v3.12+, current kube-context already
# pointed at the target cluster (`kubectl config current-context`).

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────
CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE="aggregator"
NAMESPACE="aggregator"
VALUES_FILE=""               # empty => helm uses chart's values.yaml only
IMAGE_REGISTRY=""
IMAGE_TAG=""
DRY_RUN=""
EXTRA_SET=()

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
    -r|--release)      RELEASE="$2"; shift 2 ;;
    -f|--values)       VALUES_FILE="$2"; shift 2 ;;
    -R|--registry)     IMAGE_REGISTRY="$2"; shift 2 ;;
    -t|--tag)          IMAGE_TAG="$2"; shift 2 ;;
    --set)             EXTRA_SET+=("--set" "$2"); shift 2 ;;
    --dry-run)         DRY_RUN="--dry-run"; shift ;;
    -h|--help)         usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -z "$NAMESPACE"   ]] && { echo "ERROR: -n <namespace> is required" >&2; exit 2; }
[[ ! -d "$CHART_DIR" ]] && { echo "ERROR: chart dir not found: $CHART_DIR" >&2; exit 2; }
[[ -n "$VALUES_FILE" && ! -f "$VALUES_FILE" ]] && { echo "ERROR: values file not found: $VALUES_FILE" >&2; exit 2; }

# ── Tooling check ──────────────────────────────────────────────────────────
command -v helm    >/dev/null || { echo "ERROR: helm not installed"    >&2; exit 3; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl not installed" >&2; exit 3; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERROR: cluster unreachable; check kubeconfig" >&2; exit 3; }

CTX="$(kubectl config current-context)"
echo "▶ context  : $CTX"
echo "▶ namespace: $NAMESPACE"
echo "▶ release  : $RELEASE"
echo "▶ values   : ${VALUES_FILE:-<chart default>}"
[[ -n "$IMAGE_REGISTRY" ]] && echo "▶ registry : $IMAGE_REGISTRY"
[[ -n "$IMAGE_TAG"      ]] && echo "▶ tag      : $IMAGE_TAG"

# ── Build --set overrides ──────────────────────────────────────────────────
SET_ARGS=()
[[ -n "$IMAGE_REGISTRY" ]] && SET_ARGS+=("--set" "global.imageRegistry=${IMAGE_REGISTRY}")
if [[ -n "$IMAGE_TAG" ]]; then
  SET_ARGS+=("--set" "web.image.tag=${IMAGE_TAG}")
  SET_ARGS+=("--set" "api.image.tag=${IMAGE_TAG}")
  SET_ARGS+=("--set" "worker.image.tag=${IMAGE_TAG}")
fi
SET_ARGS+=("${EXTRA_SET[@]+"${EXTRA_SET[@]}"}")

# ── Dependencies ───────────────────────────────────────────────────────────
echo "▶ verifying vendored subcharts ..."
for dep in web api worker keycloak; do
  [[ -d "${CHART_DIR}/charts/${dep}" ]] || { echo "ERROR: missing vendored subchart: charts/${dep}" >&2; exit 4; }
done

# ── Lint (fast safety net) ─────────────────────────────────────────────────
VALUES_ARGS=()
[[ -n "$VALUES_FILE" ]] && VALUES_ARGS=("-f" "$VALUES_FILE")

echo "▶ helm lint ..."
helm lint "$CHART_DIR" "${VALUES_ARGS[@]+"${VALUES_ARGS[@]}"}" >/dev/null

# ── Install / upgrade ──────────────────────────────────────────────────────
echo "▶ helm upgrade --install ..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  "${VALUES_ARGS[@]+"${VALUES_ARGS[@]}"}" \
  "${SET_ARGS[@]+"${SET_ARGS[@]}"}" \
  --wait --timeout 10m \
  $DRY_RUN

[[ -n "$DRY_RUN" ]] && { echo "✔ dry-run complete"; exit 0; }

echo
echo "✔ Release '$RELEASE' deployed to namespace '$NAMESPACE'."
echo
kubectl -n "$NAMESPACE" get pods,svc,ingress
echo
echo "Tail logs:  kubectl -n $NAMESPACE logs -f deploy/${RELEASE}-api"
echo "Uninstall:  helm uninstall $RELEASE -n $NAMESPACE"
