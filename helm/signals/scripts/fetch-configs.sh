#!/usr/bin/env bash
#
# fetch-configs.sh — pull the signals network + consent config from the canonical
# Signals-DPG repo, driven by the network/brand selected in global-values.yaml.
#
# What it does (per the served network, and its brand when set):
#   examples/schemas/<net>/network.json          -> files/networks/<net>.json
#   examples/schemas/<net>/consent.json          -> files/consent/<net>.json
#   examples/schemas/<net>/<brand>/consent.json  -> files/consent/<net>.<brand>.json   (only if brand set)
#
# The files land exactly where charts/api/templates/schemas-configmap.yaml reads
# them, so `helm upgrade` renders them into the `-schemas` ConfigMap at deploy
# time. They are fetched FRESH on every deploy and are NOT committed (see
# .gitignore), so the deployed config always tracks canonical and can never
# silently drift from it.
#
# network.json's `instance_url` (a local-dev value in canonical) is normalized to
# the `__PUBLIC_API_URL__` token, which schemas-configmap.yaml substitutes with
# the real public host at render time.
#
# Usage:
#   fetch-configs.sh --global-values <path> [--ref <git-ref>] [--repo <owner/name>]
#                    [--network <net>] [--brand <brand>] [--out-root <files-dir>]
#
# --network/--brand override what is read from global-values.yaml (_network / _brand).
# --ref defaults to $SIGNALS_DPG_REF or "develop"; pin to the api image build SHA in prod.
set -euo pipefail

REPO_DEFAULT="Blue-Dots-Economy/signals-dpg"
REF_DEFAULT="develop"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GLOBAL_VALUES=""
REF="${SIGNALS_DPG_REF:-$REF_DEFAULT}"
REPO="${SIGNALS_DPG_REPO:-$REPO_DEFAULT}"
NETWORK=""
BRAND=""
# Default output root: helm/signals/charts/api/files (relative to this script).
OUT_ROOT="$(cd "$SCRIPT_DIR/../charts/api/files" 2>/dev/null && pwd || echo "$SCRIPT_DIR/../charts/api/files")"

usage() { sed -n '2,30p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --global-values) GLOBAL_VALUES="$2"; shift 2 ;;
    --ref)           REF="$2"; shift 2 ;;
    --repo)          REPO="$2"; shift 2 ;;
    --network)       NETWORK="$2"; shift 2 ;;
    --brand)         BRAND="$2"; shift 2 ;;
    --out-root)      OUT_ROOT="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Read _network / _brand anchors from global-values.yaml when not passed explicitly.
# Anchors look like:  _network: &network "blue_dot"   /   _brand: &brand ""
read_anchor() { # <file> <anchor-name>
  grep -E "^${2}:" "$1" 2>/dev/null | sed -E "s/^${2}:[^\"]*\"([^\"]*)\".*/\1/" | head -n1 || true
}

if [ -n "$GLOBAL_VALUES" ]; then
  [ -f "$GLOBAL_VALUES" ] || { echo "ERROR: --global-values not found: $GLOBAL_VALUES" >&2; exit 1; }
  [ -n "$NETWORK" ] || NETWORK="$(read_anchor "$GLOBAL_VALUES" _network)"
  [ -n "$BRAND" ]   || BRAND="$(read_anchor "$GLOBAL_VALUES" _brand)"
fi

if [ -z "$NETWORK" ]; then
  echo "ERROR: network not set — pass --network or provide _network in --global-values" >&2
  exit 1
fi

NET_DIR="$OUT_ROOT/networks"
CONSENT_DIR="$OUT_ROOT/consent"
mkdir -p "$NET_DIR" "$CONSENT_DIR"

RAW="https://raw.githubusercontent.com/${REPO}/${REF}/examples/schemas"

fetch() { # <url> <dest>
  curl -fsSL "$1" -o "$2" || { echo "ERROR: fetch failed: $1" >&2; exit 1; }
  [ -s "$2" ] || { echo "ERROR: fetched empty file from $1" >&2; exit 1; }
}

echo "fetch-configs: repo=${REPO} ref=${REF} network=${NETWORK} brand=${BRAND:-<none>}"

# 1) network.json — normalize instance_url to the placeholder the ConfigMap substitutes.
tmp="$(mktemp)"
fetch "${RAW}/${NETWORK}/network.json" "$tmp"
sed -E 's/("instance_url"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"__PUBLIC_API_URL__"/' "$tmp" > "${NET_DIR}/${NETWORK}.json"
rm -f "$tmp"
echo "  network -> ${NET_DIR}/${NETWORK}.json"

# 2) consent.json — network default.
fetch "${RAW}/${NETWORK}/consent.json" "${CONSENT_DIR}/${NETWORK}.json"
echo "  consent -> ${CONSENT_DIR}/${NETWORK}.json"

# 3) brand consent override (partial, deep-merged over the network default by the api).
if [ -n "$BRAND" ]; then
  fetch "${RAW}/${NETWORK}/${BRAND}/consent.json" "${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
  echo "  brand consent -> ${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
fi

echo "fetch-configs: done."
