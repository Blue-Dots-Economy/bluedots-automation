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
#   aggregator  consent.json (a FULL document) from aggregator-dpg
#               config/<net>[/<brand>]/schemas/aggregator/consent.json, with a
#               brand > network > default fallback
#                 -> helm/aggregator/files/consent/consent.json
#
# Usage:
#   fetch-configs.sh signals    --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#   fetch-configs.sh aggregator --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#
# --network/--brand override the _network/_brand anchors read from global-values.yaml.
# Defaults: signals ref=develop, aggregator ref=develop; both public repos (no auth).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIGNALS_REPO_DEFAULT="Blue-Dots-Economy/signals-dpg"
SIGNALS_REF_DEFAULT="develop"
AGGREGATOR_REPO_DEFAULT="Blue-Dots-Economy/aggregator-dpg"
AGGREGATOR_REF_DEFAULT="develop"

# Canonical consent keeps a LITERAL support/grievance email; the charts expect a
# `__SUPPORT_EMAIL__` placeholder they substitute at render (PR #59, configurable
# via schemas.consentSupportEmail / global.consentSupportEmail). So after fetching
# consent we rewrite the literal back to the placeholder — keeping the email a
# deploy-time knob rather than whatever canonical hardcodes. Override if the
# canonical literal changes.
SUPPORT_EMAIL_LITERAL="${SUPPORT_EMAIL_LITERAL:-support@onest.network}"

usage() { sed -n '2,30p' "$0"; }

# Rewrite the canonical literal support email in a fetched consent file to the
# __SUPPORT_EMAIL__ placeholder the chart templates substitute.
normalize_support_email() { # <file>
  local esc="${SUPPORT_EMAIL_LITERAL//./\\.}"
  sed -i "s/${esc}/__SUPPORT_EMAIL__/g" "$1"
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
GLOBAL_VALUES=""; REF=""; REPO=""; NETWORK=""; BRAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --global-values) GLOBAL_VALUES="$2"; shift 2 ;;
    --ref)           REF="$2"; shift 2 ;;
    --repo)          REPO="$2"; shift 2 ;;
    --network)       NETWORK="$2"; shift 2 ;;
    --brand)         BRAND="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "$GLOBAL_VALUES" ]; then
  [ -f "$GLOBAL_VALUES" ] || { echo "ERROR: --global-values not found: $GLOBAL_VALUES" >&2; exit 1; }
  [ -n "$NETWORK" ] || NETWORK="$(read_anchor "$GLOBAL_VALUES" _network)"
  [ -n "$BRAND" ]   || BRAND="$(read_anchor "$GLOBAL_VALUES" _brand)"
fi
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
    ;;

  aggregator)
    REPO="${REPO:-${AGGREGATOR_DPG_REPO:-$AGGREGATOR_REPO_DEFAULT}}"
    REF="${REF:-${AGGREGATOR_DPG_REF:-$AGGREGATOR_REF_DEFAULT}}"
    RAW="https://raw.githubusercontent.com/${REPO}/${REF}/config"
    OUT="$REPO_ROOT/helm/aggregator/files/consent/consent.json"
    mkdir -p "$(dirname "$OUT")"
    echo "fetch-configs[aggregator]: repo=${REPO} ref=${REF} network=${NETWORK} brand=${BRAND:-<none>}"

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
