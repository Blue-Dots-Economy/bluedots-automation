#!/usr/bin/env bash
#
# scripts/fetch-configs.sh — pull deploy-time config from the canonical (public)
# app repos, driven by the network/brand selected in global-values.yaml, and
# write it where the helm charts render it into ConfigMaps. Files are fetched
# FRESH on every deploy and are NOT committed (see .gitignore), so the deployed
# config always tracks canonical and can never silently drift.
#
# Subcommands:
#   signals     network.json + consent.json (+ <brand>/consent.json) from
#               signals-dpg examples/schemas/<net>/
#                 -> helm/signals/charts/api/files/{networks,consent}/
#               network.json's instance_url is normalized to __PUBLIC_API_URL__
#               (the token schemas-configmap.yaml substitutes with the real host).
#               ALSO the UI's college/institute reference list for the region in
#               _college_dataset, from signals-dpg apps/ui/public/reference/
#                 -> helm/signals/charts/ui/files/reference/colleges-<region>.json
#               (rendered into the {release}-ui-reference ConfigMap). Only the ONE
#               selected region is fetched — a ConfigMap is capped at 1 MiB and the
#               two known datasets together exceed it.
#   aggregator  consent.json (a FULL document) from aggregator-dpg
#               config/<net>[/<brand>]/schemas/aggregator/consent.json, with a
#               brand > network > default fallback
#                 -> helm/aggregator/files/consent/consent.json
#
# Usage:
#   fetch-configs.sh signals    --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>] [--college-dataset <ka|up>]
#   fetch-configs.sh aggregator --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#
# --network/--brand/--college-dataset override the _network/_brand/_college_dataset
# anchors read from global-values.yaml.
# Defaults: signals ref=develop, aggregator ref=develop; both public repos (no auth).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIGNALS_REPO_DEFAULT="Blue-Dots-Economy/signals-dpg"
SIGNALS_REF_DEFAULT="develop"
AGGREGATOR_REPO_DEFAULT="Blue-Dots-Economy/aggregator-dpg"
AGGREGATOR_REF_DEFAULT="develop"

# TRANSITION SHIM (remove once the placeholder ships on the fetched ref).
# The charts expect a `__SUPPORT_EMAIL__` placeholder in consent that they
# substitute at render (PR #59, configurable via schemas.consentSupportEmail /
# global.consentSupportEmail). Canonical is migrating its consent from a literal
# support email to shipping that placeholder directly (signals-dpg#286 /
# aggregator-dpg#486 — already on `feature`, not yet on `develop`). Until the
# placeholder is on the ref we fetch, rewrite ANY known literal (the one being
# retired AND the one being migrated to) back to the placeholder, so #59's
# `replace` always has something to act on regardless of migration ordering.
# When canonical ships the placeholder on the fetched ref, these matches no-op
# and this whole shim can be deleted.
SUPPORT_EMAIL_LITERALS="${SUPPORT_EMAIL_LITERALS:-support@onest.network hello@bluedotseconomy.org}"

usage() { sed -n '2,30p' "$0"; }

# Rewrite any known literal support email in a fetched consent file to the
# __SUPPORT_EMAIL__ placeholder the chart templates substitute. No-op if the
# file already carries the placeholder (canonical post-migration).
normalize_support_email() { # <file>
  local lit esc
  for lit in $SUPPORT_EMAIL_LITERALS; do
    esc="${lit//./\\.}"
    sed -i "s/${esc}/__SUPPORT_EMAIL__/g" "$1"
  done
}

# Nudge toward reproducible deploys: a moving branch ref (develop/feature/main)
# means the fetched config can change between deploys. Pin to a tag/SHA — ideally
# the api image's build SHA — for prod. (Non-fatal; dev deploys legitimately use
# a branch.)
warn_if_moving_ref() { # <ref>
  # A pinned ref is a full hex SHA (7–40 chars) or a version tag (vX…). Anything
  # else (develop/feature/main/…) is a moving branch → warn.
  if [[ "$1" =~ ^[0-9a-f]{7,40}$ ]] || [[ "$1" =~ ^[vV][0-9] ]]; then
    return 0
  fi
  echo "  ⚠ fetching from moving ref '$1' — pin to a tag/SHA (e.g. the api image SHA) for prod/reproducible deploys" >&2
}

# Read a "_name: &anchor \"value\"" scalar anchor from global-values.yaml (no yq).
read_anchor() { # <file> <anchor-name>
  grep -E "^${2}:" "$1" 2>/dev/null | sed -E "s/^${2}:[^\"]*\"([^\"]*)\".*/\1/" | head -n1 || true
}

# Fetch the first candidate URL that returns non-empty content into <dest>.
try_fetch() { # <dest> <url>...
  local dest="$1"; shift
  local url
  for url in "$@"; do
    if curl -fsSL "$url" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
      echo "  <- ${url}"
      return 0
    fi
  done
  echo "ERROR: no candidate URL returned content for ${dest}:" >&2
  printf '       %s\n' "$@" >&2
  return 1
}

TARGET="${1:-}"; shift 2>/dev/null || true
GLOBAL_VALUES=""; REF=""; REPO=""; NETWORK=""; BRAND=""; COLLEGE_DATASET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --global-values) GLOBAL_VALUES="$2"; shift 2 ;;
    --ref)           REF="$2"; shift 2 ;;
    --repo)          REPO="$2"; shift 2 ;;
    --network)       NETWORK="$2"; shift 2 ;;
    --brand)         BRAND="$2"; shift 2 ;;
    --college-dataset) COLLEGE_DATASET="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "$GLOBAL_VALUES" ]; then
  [ -f "$GLOBAL_VALUES" ] || { echo "ERROR: --global-values not found: $GLOBAL_VALUES" >&2; exit 1; }
  [ -n "$NETWORK" ] || NETWORK="$(read_anchor "$GLOBAL_VALUES" _network)"
  [ -n "$BRAND" ]   || BRAND="$(read_anchor "$GLOBAL_VALUES" _brand)"
  [ -n "$COLLEGE_DATASET" ] || COLLEGE_DATASET="$(read_anchor "$GLOBAL_VALUES" _college_dataset)"
fi
# Must match the chart's fallback (ui.runtimeConfig.VITE_COLLEGE_DATASET default,
# itself matching the widget's own "ka" default), or we'd fetch a region the
# ConfigMap template then can't find.
COLLEGE_DATASET="${COLLEGE_DATASET:-ka}"
[ -n "$NETWORK" ] || { echo "ERROR: network not set — pass --network or provide _network in --global-values" >&2; exit 1; }

case "$TARGET" in
  signals)
    REPO="${REPO:-${SIGNALS_DPG_REPO:-$SIGNALS_REPO_DEFAULT}}"
    REF="${REF:-${SIGNALS_DPG_REF:-$SIGNALS_REF_DEFAULT}}"
    RAW="https://raw.githubusercontent.com/${REPO}/${REF}/examples/schemas"
    NET_DIR="$REPO_ROOT/helm/signals/charts/api/files/networks"
    CONSENT_DIR="$REPO_ROOT/helm/signals/charts/api/files/consent"
    mkdir -p "$NET_DIR" "$CONSENT_DIR"
    echo "fetch-configs[signals]: repo=${REPO} ref=${REF} network=${NETWORK} brand=${BRAND:-<none>}"
    warn_if_moving_ref "$REF"

    tmp="$(mktemp)"
    try_fetch "$tmp" "${RAW}/${NETWORK}/network.json"
    sed -E 's/("instance_url"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"__PUBLIC_API_URL__"/' "$tmp" > "${NET_DIR}/${NETWORK}.json"
    rm -f "$tmp"
    echo "  network -> ${NET_DIR}/${NETWORK}.json"

    try_fetch "${CONSENT_DIR}/${NETWORK}.json" "${RAW}/${NETWORK}/consent.json"
    normalize_support_email "${CONSENT_DIR}/${NETWORK}.json"
    echo "  consent -> ${CONSENT_DIR}/${NETWORK}.json"

    if [ -n "$BRAND" ]; then
      try_fetch "${CONSENT_DIR}/${NETWORK}.${BRAND}.json" "${RAW}/${NETWORK}/${BRAND}/consent.json"
      normalize_support_email "${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
      echo "  brand consent -> ${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
    fi

    # UI college/institute reference list for the selected region. Lives under
    # apps/ui/public/ (not examples/schemas/), hence its own RAW base. Only the one
    # region in _college_dataset is fetched: the ui reference ConfigMap ships
    # exactly that file, and a ConfigMap can't hold both (1 MiB etcd cap).
    REF_DIR="$REPO_ROOT/helm/signals/charts/ui/files/reference"
    mkdir -p "$REF_DIR"
    UI_RAW="https://raw.githubusercontent.com/${REPO}/${REF}/apps/ui/public/reference"
    try_fetch "${REF_DIR}/colleges-${COLLEGE_DATASET}.json" \
      "${UI_RAW}/colleges-${COLLEGE_DATASET}.json"
    # Fail loudly on non-JSON (e.g. a GitHub 404 HTML page slipping through) rather
    # than letting `helm template`'s fromJson produce a cryptic parse error.
    if command -v jq >/dev/null 2>&1; then
      jq -e . "${REF_DIR}/colleges-${COLLEGE_DATASET}.json" >/dev/null 2>&1 \
        || { echo "ERROR: fetched colleges-${COLLEGE_DATASET}.json is not valid JSON" >&2; exit 1; }
    fi
    echo "  ui reference (${COLLEGE_DATASET}) -> ${REF_DIR}/colleges-${COLLEGE_DATASET}.json"
    ;;

  aggregator)
    REPO="${REPO:-${AGGREGATOR_DPG_REPO:-$AGGREGATOR_REPO_DEFAULT}}"
    REF="${REF:-${AGGREGATOR_DPG_REF:-$AGGREGATOR_REF_DEFAULT}}"
    RAW="https://raw.githubusercontent.com/${REPO}/${REF}/config"
    OUT="$REPO_ROOT/helm/aggregator/files/consent/consent.json"
    mkdir -p "$(dirname "$OUT")"
    echo "fetch-configs[aggregator]: repo=${REPO} ref=${REF} network=${NETWORK} brand=${BRAND:-<none>}"
    warn_if_moving_ref "$REF"

    # Aggregator consent is a FULL document, one file per deployed network+brand.
    # Prefer the branded doc, then the network doc, then the repo-wide default.
    cands=()
    [ -n "$BRAND" ] && cands+=("${RAW}/${NETWORK}/${BRAND}/schemas/aggregator/consent.json")
    cands+=("${RAW}/${NETWORK}/schemas/aggregator/consent.json")
    cands+=("${RAW}/schemas/aggregator/consent.json")
    try_fetch "$OUT" "${cands[@]}"
    normalize_support_email "$OUT"
    echo "  aggregator consent -> ${OUT}"
    ;;

  *)
    echo "ERROR: unknown target '${TARGET}' (expected: signals | aggregator)" >&2
    usage; exit 2 ;;
esac

echo "fetch-configs[${TARGET}]: done."
