#!/usr/bin/env bash
#
# scripts/fetch-configs.sh — pull deploy-time config from the canonical
# use-case-schemas repo, driven by the network/brand selected in
# global-values.yaml, and write it where the helm charts render it into
# ConfigMaps. Files are fetched FRESH on every deploy and are NOT committed
# (see .gitignore), so the deployed config always tracks canonical and can
# never silently drift.
#
# Canonical source is the unified repo Blue-Dots-Economy/bluedots-schemas
# with a flat per-network layout at the repo root:
#   <network>/network.json
#   <network>/consent.json
#   <network>/<brand>/consent.json
# (network/brand dir names use underscores, e.g. blue_dot, orange_dot, upsdm).
#
# Subcommands:
#   signals     network.json + consent.json (+ <brand>/consent.json) from
#               <network>/ in the schemas repo
#                 -> helm/signals/charts/api/files/{networks,consent}/
#               network.json's instance_url is normalized to __PUBLIC_API_URL__
#               (the token schemas-configmap.yaml substitutes with the real host).
#   aggregator  consent.json (a FULL document) from <network>[/<brand>]/consent.json
#               in the schemas repo, with a brand > network fallback
#                 -> helm/aggregator/files/consent/consent.json
#
# Usage:
#   fetch-configs.sh signals    --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#   fetch-configs.sh aggregator --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#
# --network/--brand override the _network/_brand anchors read from global-values.yaml.
# Defaults: both targets ref=main, repo=bluedots-schemas.
# Auth: anonymous if the repo is public; if it is private, export SCHEMAS_PAT
# (fine-grained token with Contents:read; GHCR_PAT accepted as a fallback) and the
# fetch switches to the authenticated GitHub Contents API automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Unified schemas repo (per-network dirs at the repo root). Both targets pull
# from the same repo; kept as separate constants so a target can be repinned
# independently via SIGNALS_DPG_REPO / AGGREGATOR_DPG_REPO if ever needed.
SIGNALS_REPO_DEFAULT="Blue-Dots-Economy/bluedots-schemas"
SIGNALS_REF_DEFAULT="main"
AGGREGATOR_REPO_DEFAULT="Blue-Dots-Economy/bluedots-schemas"
AGGREGATOR_REF_DEFAULT="main"

# Optional auth for a PRIVATE schemas repo. If a token is present we fetch via the
# GitHub Contents API (the reliable way to pull raw file content from a private
# repo); if empty we fetch anonymously from raw.githubusercontent.com (public repo).
# SCHEMAS_PAT is the dedicated token (fine-grained, Contents:read on the schemas
# repo); GHCR_PAT is accepted as a fallback but must carry repo/contents scope
# (its default read:packages scope is NOT enough — that path 403s and try_fetch
# then reports no content).
GH_TOKEN="${SCHEMAS_PAT:-${GHCR_PAT:-}}"

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

usage() { sed -n '2,35p' "$0"; }

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
# Callers pass raw.githubusercontent.com URLs; when GH_TOKEN is set we transparently
# rewrite each to the authenticated GitHub Contents API endpoint (raw content) so the
# same call sites work against a private repo.
try_fetch() { # <dest> <url>...
  local dest="$1"; shift
  local url fetch_url ok
  for url in "$@"; do
    fetch_url="$url"
    if [ -n "$GH_TOKEN" ] && [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
      fetch_url="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/contents/${BASH_REMATCH[4]}?ref=${BASH_REMATCH[3]}"
    fi
    if [ -n "$GH_TOKEN" ]; then
      ok=$(curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github.raw" "$fetch_url" -o "$dest" 2>/dev/null && echo y || echo n)
    else
      ok=$(curl -fsSL "$fetch_url" -o "$dest" 2>/dev/null && echo y || echo n)
    fi
    if [ "$ok" = y ] && [ -s "$dest" ]; then
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
    RAW="https://raw.githubusercontent.com/${REPO}/${REF}"
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
    ;;

  aggregator)
    REPO="${REPO:-${AGGREGATOR_DPG_REPO:-$AGGREGATOR_REPO_DEFAULT}}"
    REF="${REF:-${AGGREGATOR_DPG_REF:-$AGGREGATOR_REF_DEFAULT}}"
    RAW="https://raw.githubusercontent.com/${REPO}/${REF}"
    OUT="$REPO_ROOT/helm/aggregator/files/consent/consent.json"
    mkdir -p "$(dirname "$OUT")"
    echo "fetch-configs[aggregator]: repo=${REPO} ref=${REF} network=${NETWORK} brand=${BRAND:-<none>}"
    warn_if_moving_ref "$REF"

    # Aggregator consent is a FULL document, one file per deployed network+brand.
    # Prefer the branded doc, then fall back to the network-level doc.
    cands=()
    [ -n "$BRAND" ] && cands+=("${RAW}/${NETWORK}/${BRAND}/consent.json")
    cands+=("${RAW}/${NETWORK}/consent.json")
    try_fetch "$OUT" "${cands[@]}"
    normalize_support_email "$OUT"
    echo "  aggregator consent -> ${OUT}"
    ;;

  *)
    echo "ERROR: unknown target '${TARGET}' (expected: signals | aggregator)" >&2
    usage; exit 2 ;;
esac

echo "fetch-configs[${TARGET}]: done."
