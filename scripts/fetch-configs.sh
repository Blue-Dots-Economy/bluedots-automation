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
#   <network>/messages.properties
#   <network>/<brand>/messages.properties
# (network/brand dir names use underscores, e.g. blue_dot, orange_dot, upsdm).
#
# Subcommands:
#   signals     network.json + consent.json (+ <brand>/consent.json) from
#               <network>/ in the schemas repo
#                 -> helm/signals/charts/api/files/{networks,consent}/
#               network.json's instance_url is normalized to __PUBLIC_API_URL__
#               (the token schemas-configmap.yaml substitutes with the real host).
#               PLUS messages.properties (+ <brand>/messages.properties) — the
#               per-network email copy (signals-dpg#540)
#                 -> helm/signals/charts/api/files/messages/
#               OPTIONAL, unlike consent: the api ships complete bundled email
#               copy and merges these PER KEY, so a network with no file (or a
#               ref predating them) keeps the built-in wording instead of
#               failing the deploy.
#   aggregator  consent.json (a FULL document) from the aggregator-dpg config tree.
#               The aggregator's loader requires a top-level {"audiences":…};
#               bluedots-schemas' <network>/consent.json is the signals document
#               ({"documents":…}) — a different schema under the same filename.
#               Candidates, brand > network > repo-wide default:
#                 <consent-dir>/<network>/<brand>/schemas/aggregator/consent.json
#                 <consent-dir>/<network>/schemas/aggregator/consent.json
#                 <consent-dir>/schemas/aggregator/consent.json
#                 -> helm/aggregator/files/consent/consent.json
#               Shape is asserted (assert_aggregator_consent) because the app
#               tolerates a bad document instead of failing.
#               PLUS aggregator.config.yaml (network binding, brand strings, domain
#               labels, registration modes), also from aggregator-dpg but with its
#               own repo/ref/dir/file knobs:
#                 <config-dir>/<network>[/<brand>]/<config-file>
#                 -> helm/aggregator/files/network-config/aggregator.config.yaml
#               Fetched VERBATIM — no placeholder rewriting, no field edits. The
#               chart mounts it over the image-baked copy, so updating canonical +
#               redeploying picks it up with NO image rebuild.
#
# Usage:
#   fetch-configs.sh signals    --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>] [--college-dataset <ka|up>]
#   fetch-configs.sh aggregator --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#
# aggregator consent source knobs (flag > env > default), independent of both the
# schemas repo and the aggregator.config.yaml source above:
#   --consent-repo / AGGREGATOR_CONSENT_REPO default Blue-Dots-Economy/aggregator-dpg
#   --consent-ref  / AGGREGATOR_CONSENT_REF  default develop   (pin a tag/SHA for prod)
#   --consent-dir  / AGGREGATOR_CONSENT_DIR  default config    (empty = repo root)
#
# --network/--brand/--college-dataset override the _network/_brand/_college_dataset
# anchors read from global-values.yaml.
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

# aggregator.config.yaml source — INDEPENDENT of the consent/network source above.
# It lives in the aggregator-dpg repo's config/ tree (the canonical home; the
# unified schemas repo does not carry it yet). Repo, ref, dir and filename are all
# overridable via flags or env so this can be repointed — e.g. to bluedots-schemas
# once it ships aggregator.config.yaml — without touching the charts.
AGGREGATOR_CONFIG_REPO_DEFAULT="Blue-Dots-Economy/aggregator-dpg"
AGGREGATOR_CONFIG_REF_DEFAULT="develop"
AGGREGATOR_CONFIG_DIR_DEFAULT="config"
AGGREGATOR_CONFIG_FILE_DEFAULT="aggregator.config.yaml"

# Aggregator consent source. Separate from the schemas repo above: the aggregator
# consent is an {"audiences":…} document that lives in the aggregator-dpg config
# tree. Separate from the config source below too, so the consent doc and
# aggregator.config.yaml can be pinned to different refs.
AGGREGATOR_CONSENT_REPO_DEFAULT="Blue-Dots-Economy/aggregator-dpg"
AGGREGATOR_CONSENT_REF_DEFAULT="develop"
AGGREGATOR_CONSENT_DIR_DEFAULT="config"

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

# Print the header comment block as help. Reads to the first non-comment line
# rather than a hardcoded range, so growing the header can't silently truncate
# usage (or start printing code).
usage() { awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; }

# Validate the fetched aggregator consent. The app renders a generic fallback
# rather than erroring on a document it cannot read, so the shape is checked here
# where a wrong source can still fail the deploy.
assert_aggregator_consent() { # <file>
  if grep -q '"audiences"' "$1"; then
    # bulk_upload_attestation is optional in the schema but drives the operator
    # attestation shown before a bulk upload; warn rather than fail, since
    # privacy+terms alone is a valid consent set.
    if ! grep -q '"bulk_upload_attestation"' "$1"; then
      echo "  ⚠ consent has no 'bulk_upload_attestation' document — bulk upload will show" >&2
      echo "    the generic attestation label. Check --consent-ref." >&2
    fi
    return 0
  fi
  echo "ERROR: fetched consent has no top-level \"audiences\" key: ${1}" >&2
  if grep -q '"documents"' "$1"; then
    echo "       It has \"documents\" — that is the signals consent schema." >&2
    echo "       Aggregator consent lives in aggregator-dpg at" >&2
    echo "       config/[<network>/[<brand>/]]schemas/aggregator/consent.json" >&2
    echo "       (check --consent-repo / --consent-dir)." >&2
  fi
  return 1
}

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

# try_fetch for a genuinely OPTIONAL file — one the app has its own fallback for,
# so a miss is reported and shrugged off instead of failing the deploy. Removes
# the destination on a miss, so the chart's Files.Get presence check sees
# "absent" rather than an empty file.
fetch_optional() { # <dest> <url> <label> <fallback-note>
  if try_fetch "$1" "$2" 2>/dev/null; then
    echo "  $3 -> $1"
  else
    rm -f "$1"
    echo "  $3: absent on ${REF} — $4"
  fi
}

TARGET="${1:-}"; shift 2>/dev/null || true
GLOBAL_VALUES=""; REF=""; REPO=""; NETWORK=""; BRAND=""; COLLEGE_DATASET=""
CFG_REPO=""; CFG_REF=""; CFG_DIR=""; CFG_FILE=""; CFG_DIR_SET=0
CONSENT_REPO=""; CONSENT_REF=""; CONSENT_DIR=""; CONSENT_DIR_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --global-values) GLOBAL_VALUES="$2"; shift 2 ;;
    --ref)           REF="$2"; shift 2 ;;
    --repo)          REPO="$2"; shift 2 ;;
    --network)       NETWORK="$2"; shift 2 ;;
    --brand)         BRAND="$2"; shift 2 ;;
    --college-dataset) COLLEGE_DATASET="$2"; shift 2 ;;
    # aggregator.config.yaml source overrides (aggregator target only).
    --config-repo)   CFG_REPO="$2"; shift 2 ;;
    --config-ref)    CFG_REF="$2"; shift 2 ;;
    # --config-dir "" is meaningful (= repo root), so track "was it passed?"
    # separately rather than inferring from emptiness.
    --config-dir)    CFG_DIR="$2"; CFG_DIR_SET=1; shift 2 ;;
    --config-file)   CFG_FILE="$2"; shift 2 ;;
    # aggregator consent source overrides (aggregator target only).
    --consent-repo)  CONSENT_REPO="$2"; shift 2 ;;
    --consent-ref)   CONSENT_REF="$2"; shift 2 ;;
    --consent-dir)   CONSENT_DIR="$2"; CONSENT_DIR_SET=1; shift 2 ;;
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

    # ── per-network email copy (signals-dpg#540) ──────────────────────────────
    # Rides the consent ConfigMap: the api resolves both from
    # dirname(NETWORK_CONFIG_LOCAL_FILE). Optional per key, so a missing file
    # just keeps the api's bundled wording. Cleared first because the chart
    # renders on file presence alone — a leftover from an earlier deploy of a
    # different network/brand would otherwise override this one's copy.
    # Full rationale: helm/CLAUDE.md, "Email copy rides the signals consent ConfigMap".
    MESSAGES_DIR="$REPO_ROOT/helm/signals/charts/api/files/messages"
    mkdir -p "$MESSAGES_DIR"
    rm -f "$MESSAGES_DIR"/*.properties

    fetch_optional "${MESSAGES_DIR}/${NETWORK}.properties" \
      "${RAW}/${NETWORK}/messages.properties" \
      "email copy" "api keeps its bundled defaults"

    if [ -n "$BRAND" ]; then
      fetch_optional "${MESSAGES_DIR}/${NETWORK}.${BRAND}.properties" \
        "${RAW}/${NETWORK}/${BRAND}/messages.properties" \
        "brand email copy" "network/bundled copy only"
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
    RAW="https://raw.githubusercontent.com/${REPO}/${REF}"
    OUT="$REPO_ROOT/helm/aggregator/files/consent/consent.json"
    mkdir -p "$(dirname "$OUT")"
    echo "fetch-configs[aggregator]: repo=${REPO} ref=${REF} network=${NETWORK} brand=${BRAND:-<none>}"
    warn_if_moving_ref "$REF"

    # ── aggregator consent ────────────────────────────────────────────────────
    # From the aggregator-dpg config tree, not the schemas repo: the aggregator's
    # loader requires {"audiences": {org, aggregator}}
    # (packages/config-loader AggregatorConsentConfigSchema), whereas the schemas
    # repo's <network>/consent.json is the signals {"documents":…} schema.
    CONSENT_REPO="${CONSENT_REPO:-${AGGREGATOR_CONSENT_REPO:-$AGGREGATOR_CONSENT_REPO_DEFAULT}}"
    CONSENT_REF="${CONSENT_REF:-${AGGREGATOR_CONSENT_REF:-$AGGREGATOR_CONSENT_REF_DEFAULT}}"
    if [ "$CONSENT_DIR_SET" -eq 0 ]; then
      CONSENT_DIR="${AGGREGATOR_CONSENT_DIR-$AGGREGATOR_CONSENT_DIR_DEFAULT}"
    fi
    CONSENT_BASE="https://raw.githubusercontent.com/${CONSENT_REPO}/${CONSENT_REF}"
    [ -n "$CONSENT_DIR" ] && CONSENT_BASE="${CONSENT_BASE}/${CONSENT_DIR}"
    echo "  consent source: repo=${CONSENT_REPO} ref=${CONSENT_REF} dir=${CONSENT_DIR:-<root>}"
    warn_if_moving_ref "$CONSENT_REF"

    # A FULL document (not a partial override), one per deployed network+brand.
    # brand > network > repo-wide default. The repo-wide default is required, not
    # decorative: some networks (e.g. blue_dot) ship no aggregator consent of their
    # own and resolve entirely via it.
    cands=()
    [ -n "$BRAND" ] && cands+=("${CONSENT_BASE}/${NETWORK}/${BRAND}/schemas/aggregator/consent.json")
    cands+=("${CONSENT_BASE}/${NETWORK}/schemas/aggregator/consent.json")
    cands+=("${CONSENT_BASE}/schemas/aggregator/consent.json")
    try_fetch "$OUT" "${cands[@]}"
    assert_aggregator_consent "$OUT"
    normalize_support_email "$OUT"
    echo "  aggregator consent -> ${OUT}"

    # ── aggregator.config.yaml ────────────────────────────────────────────────
    # Network binding, brand strings, domain labels, registration modes. Its own
    # repo/ref/dir/file knobs so it can be pinned independently of the consent doc.
    # templates/network-config-configmap.yaml requires this file, so a missing
    # fetch here fails the helm render rather than degrading.
    CFG_REPO="${CFG_REPO:-${AGGREGATOR_CONFIG_REPO:-$AGGREGATOR_CONFIG_REPO_DEFAULT}}"
    CFG_REF="${CFG_REF:-${AGGREGATOR_CONFIG_REF:-$AGGREGATOR_CONFIG_REF_DEFAULT}}"
    if [ "$CFG_DIR_SET" -eq 0 ]; then
      CFG_DIR="${AGGREGATOR_CONFIG_DIR-$AGGREGATOR_CONFIG_DIR_DEFAULT}"
    fi
    CFG_FILE="${CFG_FILE:-${AGGREGATOR_CONFIG_FILE:-$AGGREGATOR_CONFIG_FILE_DEFAULT}}"
    CFG_BASE="https://raw.githubusercontent.com/${CFG_REPO}/${CFG_REF}"
    [ -n "$CFG_DIR" ] && CFG_BASE="${CFG_BASE}/${CFG_DIR}"
    CFG_OUT="$REPO_ROOT/helm/aggregator/files/network-config/aggregator.config.yaml"
    mkdir -p "$(dirname "$CFG_OUT")"
    echo "  aggregator.config source: repo=${CFG_REPO} ref=${CFG_REF} dir=${CFG_DIR:-<root>} file=${CFG_FILE}"
    warn_if_moving_ref "$CFG_REF"

    # Brand copy first — a brand folder is a full copy of its network folder, not a
    # partial override. Fetched verbatim; the chart mounts it over the image copy.
    cands=()
    [ -n "$BRAND" ] && cands+=("${CFG_BASE}/${NETWORK}/${BRAND}/${CFG_FILE}")
    cands+=("${CFG_BASE}/${NETWORK}/${CFG_FILE}")
    try_fetch "$CFG_OUT" "${cands[@]}"
    echo "  aggregator config -> ${CFG_OUT}"
    ;;

  *)
    echo "ERROR: unknown target '${TARGET}' (expected: signals | aggregator)" >&2
    usage; exit 2 ;;
esac

echo "fetch-configs[${TARGET}]: done."