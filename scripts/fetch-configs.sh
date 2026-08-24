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
#               network.json prefers the BRAND copy outright (a brand network
#               schema is always a full document). Brand CONSENT is not always
#               full, so --consent-brand-mode (auto|replace|merge, default auto)
#               decides: a brand file covering every key the network default
#               defines is served AS consent.json and the network default is not
#               delivered at all (up-gzb); a partial one ships alongside it for
#               the api to deep-merge (upsdm, onetac). See the brand consent
#               block below.
#               PLUS messages.properties (+ <brand>/messages.properties) — the
#               per-network email copy (signals-dpg#540)
#                 -> helm/signals/charts/api/files/messages/
#               OPTIONAL, unlike consent: the api ships complete bundled email
#               copy and merges these PER KEY, so a network with no file (or a
#               ref predating them) keeps the built-in wording instead of
#               failing the deploy.
#   aggregator  consent.json (a FULL document), canonical in bluedots-schemas —
#               the SAME repo network.json comes from, resolved brand > network the
#               same way. NOTE it is NOT the same file as <network>/consent.json in
#               that repo: the aggregator's loader requires a top-level
#               {"audiences":…}, while <network>/consent.json is the signals
#               document ({"documents":…}) — a different schema under the same
#               filename, which is why it sits under schemas/aggregator/.
#               Candidates, in order — the schemas repo first, then the
#               aggregator-dpg config tree as a fallback for networks that have not
#               migrated their aggregator consent yet (e.g. orange_dot):
#                 <consent-dir>/<network>/<brand>/schemas/aggregator/consent.json
#                 <consent-dir>/<network>/schemas/aggregator/consent.json
#                 <fallback-dir>/<network>/<brand>/schemas/aggregator/consent.json
#                 <fallback-dir>/<network>/schemas/aggregator/consent.json
#                 <fallback-dir>/schemas/aggregator/consent.json
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
#   fetch-configs.sh signals    --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>] [--college-dataset <ka|up>] [--consent-brand-mode <auto|replace|merge>]
#   fetch-configs.sh aggregator --global-values <path> [--ref <r>] [--repo <o/n>] [--network <n>] [--brand <b>]
#
# aggregator consent source knobs (flag > env > default), independent of the
# aggregator.config.yaml source above:
#   --consent-repo / AGGREGATOR_CONSENT_REPO default Blue-Dots-Economy/bluedots-schemas
#   --consent-ref  / AGGREGATOR_CONSENT_REF  default main      (pin a tag/SHA for prod)
#   --consent-dir  / AGGREGATOR_CONSENT_DIR  default <empty>   (= repo root)
#
# …and the legacy fallback source, tried only if the above misses:
#   --consent-fallback-repo / AGGREGATOR_CONSENT_FALLBACK_REPO default Blue-Dots-Economy/aggregator-dpg
#   --consent-fallback-ref  / AGGREGATOR_CONSENT_FALLBACK_REF  default main
#   --consent-fallback-dir  / AGGREGATOR_CONSENT_FALLBACK_DIR  default config (empty = repo root)
# Pass --consent-fallback-repo "" to require the schemas repo and fail loudly
# otherwise (recommended once a network's consent has migrated).
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

# Aggregator consent source. Now the unified schemas repo — the same repo, ref and
# brand > network resolution network.json uses — with the layout it already ships:
#   <network>/<brand>/schemas/aggregator/consent.json
# (blue_dot/up-gzb landed there in bluedots-schemas#20). Still its own knobs rather
# than reusing AGGREGATOR_REF: this is a distinct {"audiences":…} document from the
# signals <network>/consent.json, and it stays pinnable independently of both that
# and aggregator.config.yaml.
AGGREGATOR_CONSENT_REPO_DEFAULT="Blue-Dots-Economy/bluedots-schemas"
AGGREGATOR_CONSENT_REF_DEFAULT="main"
AGGREGATOR_CONSENT_DIR_DEFAULT=""

# Legacy fallback: the aggregator-dpg config/ tree, where the aggregator consent
# lived before the migration. Tried only after the schemas repo misses, so networks
# that have not moved yet (orange_dot, and the repo-wide default document some
# networks resolve entirely via) keep deploying unchanged. Set the repo to "" to
# disable the fallback and make a missing schemas-repo consent a hard failure.
AGGREGATOR_CONSENT_FALLBACK_REPO_DEFAULT="Blue-Dots-Economy/aggregator-dpg"
AGGREGATOR_CONSENT_FALLBACK_REF_DEFAULT="main"
AGGREGATOR_CONSENT_FALLBACK_DIR_DEFAULT="config"

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

# Does <brand-file> cover every consent key <network-file> defines?
#
# This is what decides whether the brand document can BE the served consent.json
# or has to ride alongside it as a partial override. The signals loader
# (packages/config/src/consent_config_loader.ts) resolves per key —
# `pick(brand)?.[category] ?? pick(def)?.[category]` — so a brand file that
# defines every key never consults the network default, and delivering both is
# pure duplication. One that does NOT (upsdm ships only documents.privacy +
# documents.terms; onetac the same) depends on the default for profile_creation,
# the u18_documents set and every action consent — promoting it would silently
# drop those and break U18 go-live gating and action consent.
#
# Compared as a KEY SET, not by content: identical keys with different copy is
# exactly the case we want to collapse. Needs jq; without it the caller falls
# back to the two-file merge delivery, which is correct for every brand, just
# not minimal.
consent_key_set() { # <file>
  jq -S -r '[ (.documents      // {} | keys[] | "doc." + .),
              (.u18_documents  // {} | keys[] | "u18." + .),
              (.actions // {} | to_entries[] | .key as $a
                 | (.value | keys[]) | "act." + $a + "." + .) ] | sort | .[]' "$1"
}

brand_consent_is_complete() { # <brand-file> <network-file>
  command -v jq >/dev/null 2>&1 || return 1
  local missing
  # Keys in the network default that the brand file does not define. Empty = the
  # brand document stands alone.
  missing="$(comm -23 <(consent_key_set "$2") <(consent_key_set "$1") 2>/dev/null)" || return 1
  [ -z "$missing" ]
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
#
# Timeouts are not optional here. raw.githubusercontent.com resolves to several
# IPs and any one of them can be black-holed from a given network; curl then
# waits out the TCP SYN retransmission (10-15s) before trying the next. With five
# sequential fetches per deploy that turns into minutes of a silent stall in the
# middle of `deploy_signals`. --connect-timeout caps each attempt and --retry
# moves on, so a dead IP costs seconds instead of minutes.
#
# --retry-max-time is what keeps the retries from making things WORSE: curl treats
# a --max-time expiry as retryable, so on a genuinely slow link the retries would
# otherwise multiply it (4 x 60s ≈ 4 min for one file — worse than the stall this
# was written to fix). --retry-max-time bounds the whole attempt sequence.
#
# --speed-limit/--speed-time rather than a tight --max-time: they abort a transfer
# that has STALLED (under 1 KB/s for 20s) while leaving a slow-but-progressing
# download alone, so colleges-ka.json (~570KB) is never truncated just for being
# slow. --max-time stays as a generous absolute backstop.
# Overridable: FETCH_CONNECT_TIMEOUT, FETCH_MAX_TIME, FETCH_RETRIES,
#              FETCH_RETRY_MAX_TIME.
CURL_CONNECT_TIMEOUT="${FETCH_CONNECT_TIMEOUT:-5}"   # per-attempt TCP connect cap
CURL_MAX_TIME="${FETCH_MAX_TIME:-120}"               # absolute backstop per attempt
CURL_RETRIES="${FETCH_RETRIES:-3}"
CURL_RETRY_MAX_TIME="${FETCH_RETRY_MAX_TIME:-90}"    # cap on ALL attempts combined
CURL_OPTS=(
  --connect-timeout "$CURL_CONNECT_TIMEOUT"
  --max-time "$CURL_MAX_TIME"
  --speed-limit 1024
  --speed-time 20
  --retry "$CURL_RETRIES"
  --retry-max-time "$CURL_RETRY_MAX_TIME"
  --retry-connrefused
  --retry-delay 1
)

try_fetch() { # <dest> <url>...
  local dest="$1"; shift
  local url fetch_url ok tmp
  # Download to a temp file and only move it into place on success. curl -o writes
  # incrementally, so an aborted transfer (timeout, stalled link) would otherwise
  # leave a TRUNCATED file at $dest that the `-s` non-empty check still accepts —
  # and a half-written network.json is worse than a missing one.
  tmp="$(mktemp "${dest}.XXXXXX")"
  for url in "$@"; do
    fetch_url="$url"
    if [ -n "$GH_TOKEN" ] && [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$ ]]; then
      fetch_url="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/contents/${BASH_REMATCH[4]}?ref=${BASH_REMATCH[3]}"
    fi
    if [ -n "$GH_TOKEN" ]; then
      ok=$(curl -fsSL "${CURL_OPTS[@]}" -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github.raw" "$fetch_url" -o "$tmp" 2>/dev/null && echo y || echo n)
    else
      ok=$(curl -fsSL "${CURL_OPTS[@]}" "$fetch_url" -o "$tmp" 2>/dev/null && echo y || echo n)
    fi
    if [ "$ok" = y ] && [ -s "$tmp" ]; then
      mv -f "$tmp" "$dest"
      echo "  <- ${url}"
      return 0
    fi
  done
  rm -f "$tmp"
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
# auto | replace | merge — see the brand consent block in the signals target.
CONSENT_BRAND_MODE="${CONSENT_BRAND_MODE:-auto}"
CFG_REPO=""; CFG_REF=""; CFG_DIR=""; CFG_FILE=""; CFG_DIR_SET=0
CONSENT_REPO=""; CONSENT_REF=""; CONSENT_DIR=""; CONSENT_DIR_SET=0
# --consent-fallback-repo "" is meaningful (= disable the fallback), so the
# "was it passed?" flag matters here for the repo too, not just the dir.
CONSENT_FB_REPO=""; CONSENT_FB_REPO_SET=0
CONSENT_FB_REF=""; CONSENT_FB_DIR=""; CONSENT_FB_DIR_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --global-values) GLOBAL_VALUES="$2"; shift 2 ;;
    --ref)           REF="$2"; shift 2 ;;
    --repo)          REPO="$2"; shift 2 ;;
    --network)       NETWORK="$2"; shift 2 ;;
    --brand)         BRAND="$2"; shift 2 ;;
    --college-dataset) COLLEGE_DATASET="$2"; shift 2 ;;
    --consent-brand-mode) CONSENT_BRAND_MODE="$2"; shift 2 ;;
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
    --consent-fallback-repo) CONSENT_FB_REPO="$2"; CONSENT_FB_REPO_SET=1; shift 2 ;;
    --consent-fallback-ref)  CONSENT_FB_REF="$2"; shift 2 ;;
    --consent-fallback-dir)  CONSENT_FB_DIR="$2"; CONSENT_FB_DIR_SET=1; shift 2 ;;
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
case "$CONSENT_BRAND_MODE" in
  auto|replace|merge) ;;
  *) echo "ERROR: --consent-brand-mode must be auto|replace|merge (got '${CONSENT_BRAND_MODE}')" >&2; exit 2 ;;
esac
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
    # Brand copy first — a brand folder is a FULL copy of its network folder, not
    # a partial override (same convention as the aggregator consent/config below).
    # Unlike consent, a network schema is a whole document, so there is nothing to
    # deep-merge: the brand file simply wins. up-gzb's is the copy that carries the
    # service_provider domain, absent from blue_dot/network.json — without this,
    # signals and the aggregator (which resolves the brand file itself via
    # global.networkSource.brand) render different schemas. The DESTINATION
    # filename is unchanged, so the ConfigMap key, the `items` mapping and
    # NETWORK_CONFIG_LOCAL_FILE all stay exactly as they are.
    cands=()
    [ -n "$BRAND" ] && cands+=("${RAW}/${NETWORK}/${BRAND}/network.json")
    cands+=("${RAW}/${NETWORK}/network.json")
    try_fetch "$tmp" "${cands[@]}"
    sed -E 's/("instance_url"[[:space:]]*:[[:space:]]*)"[^"]*"/\1"__PUBLIC_API_URL__"/' "$tmp" > "${NET_DIR}/${NETWORK}.json"
    rm -f "$tmp"
    echo "  network -> ${NET_DIR}/${NETWORK}.json"

    try_fetch "${CONSENT_DIR}/${NETWORK}.json" "${RAW}/${NETWORK}/consent.json"
    normalize_support_email "${CONSENT_DIR}/${NETWORK}.json"
    echo "  consent -> ${CONSENT_DIR}/${NETWORK}.json"

    # ── brand consent: replace vs merge ───────────────────────────────────────
    # Unlike network.json, a brand consent file is NOT always a full copy, so it
    # cannot unconditionally win the way the network schema does.
    #
    #   replace — the brand document defines every key the network default does
    #             (up-gzb). It is served AS consent.json, the only consent in the
    #             ConfigMap, and no brand subdir is mounted. Nothing from the
    #             network default can reach a user.
    #   merge   — the brand document is a genuine partial (upsdm, onetac). Both
    #             files ship and the api deep-merges per key, as before.
    #
    # `auto` picks per deploy from the fetched files; force with
    # --consent-brand-mode. A stale file from a previous deploy in the OTHER mode
    # is removed either way — the chart renders on file presence, so a leftover
    # would resurrect the delivery we just decided against.
    if [ -n "$BRAND" ]; then
      brand_tmp="$(mktemp)"
      try_fetch "$brand_tmp" "${RAW}/${NETWORK}/${BRAND}/consent.json"
      normalize_support_email "$brand_tmp"

      mode="$CONSENT_BRAND_MODE"
      if [ "$mode" = auto ]; then
        if brand_consent_is_complete "$brand_tmp" "${CONSENT_DIR}/${NETWORK}.json"; then
          mode=replace
        else
          mode=merge
          command -v jq >/dev/null 2>&1 \
            || echo "  ⚠ jq not found — cannot test brand consent coverage, using merge" >&2
        fi
      fi

      if [ "$mode" = replace ]; then
        mv -f "$brand_tmp" "${CONSENT_DIR}/${NETWORK}.json"
        rm -f "${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
        echo "  brand consent (${BRAND}) is a FULL document -> served as consent.json"
        echo "  consent -> ${CONSENT_DIR}/${NETWORK}.json (brand copy; network default not delivered)"
      else
        mv -f "$brand_tmp" "${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
        echo "  brand consent (${BRAND}) is a PARTIAL override -> merged over the network default"
        echo "  brand consent -> ${CONSENT_DIR}/${NETWORK}.${BRAND}.json"
      fi
      rm -f "$brand_tmp"
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
    # Canonical is the unified schemas repo, resolved brand > network exactly like
    # network.json — up-gzb's document lives at
    #   blue_dot/up-gzb/schemas/aggregator/consent.json
    # It is deliberately NOT the schemas repo's <network>/consent.json: the
    # aggregator's loader requires {"audiences": {org, aggregator}}
    # (packages/config-loader AggregatorConsentConfigSchema), whereas
    # <network>/consent.json is the signals {"documents":…} schema. Same filename,
    # different document — hence the schemas/aggregator/ sub-path.
    CONSENT_REPO="${CONSENT_REPO:-${AGGREGATOR_CONSENT_REPO:-$AGGREGATOR_CONSENT_REPO_DEFAULT}}"
    CONSENT_REF="${CONSENT_REF:-${AGGREGATOR_CONSENT_REF:-$AGGREGATOR_CONSENT_REF_DEFAULT}}"
    if [ "$CONSENT_DIR_SET" -eq 0 ]; then
      CONSENT_DIR="${AGGREGATOR_CONSENT_DIR-$AGGREGATOR_CONSENT_DIR_DEFAULT}"
    fi
    CONSENT_BASE="https://raw.githubusercontent.com/${CONSENT_REPO}/${CONSENT_REF}"
    [ -n "$CONSENT_DIR" ] && CONSENT_BASE="${CONSENT_BASE}/${CONSENT_DIR}"
    echo "  consent source: repo=${CONSENT_REPO} ref=${CONSENT_REF} dir=${CONSENT_DIR:-<root>}"
    warn_if_moving_ref "$CONSENT_REF"

    # Legacy source, tried only after the schemas repo misses. Empty repo = the
    # operator has opted out of the fallback, so a missing canonical document
    # fails the deploy instead of silently resolving to a pre-migration copy.
    if [ "$CONSENT_FB_REPO_SET" -eq 0 ]; then
      CONSENT_FB_REPO="${AGGREGATOR_CONSENT_FALLBACK_REPO-$AGGREGATOR_CONSENT_FALLBACK_REPO_DEFAULT}"
    fi
    CONSENT_FB_REF="${CONSENT_FB_REF:-${AGGREGATOR_CONSENT_FALLBACK_REF:-$AGGREGATOR_CONSENT_FALLBACK_REF_DEFAULT}}"
    if [ "$CONSENT_FB_DIR_SET" -eq 0 ]; then
      CONSENT_FB_DIR="${AGGREGATOR_CONSENT_FALLBACK_DIR-$AGGREGATOR_CONSENT_FALLBACK_DIR_DEFAULT}"
    fi

    # A FULL document (not a partial override), one per deployed network+brand.
    # Schemas repo brand > network, then the fallback's brand > network > repo-wide
    # default. That repo-wide default is not decorative: some networks (e.g. plain
    # blue_dot) ship no aggregator consent of their own and resolve entirely via it.
    cands=()
    [ -n "$BRAND" ] && cands+=("${CONSENT_BASE}/${NETWORK}/${BRAND}/schemas/aggregator/consent.json")
    cands+=("${CONSENT_BASE}/${NETWORK}/schemas/aggregator/consent.json")
    if [ -n "$CONSENT_FB_REPO" ]; then
      CONSENT_FB_BASE="https://raw.githubusercontent.com/${CONSENT_FB_REPO}/${CONSENT_FB_REF}"
      [ -n "$CONSENT_FB_DIR" ] && CONSENT_FB_BASE="${CONSENT_FB_BASE}/${CONSENT_FB_DIR}"
      echo "  consent fallback: repo=${CONSENT_FB_REPO} ref=${CONSENT_FB_REF} dir=${CONSENT_FB_DIR:-<root>}"
      warn_if_moving_ref "$CONSENT_FB_REF"
      [ -n "$BRAND" ] && cands+=("${CONSENT_FB_BASE}/${NETWORK}/${BRAND}/schemas/aggregator/consent.json")
      cands+=("${CONSENT_FB_BASE}/${NETWORK}/schemas/aggregator/consent.json")
      cands+=("${CONSENT_FB_BASE}/schemas/aggregator/consent.json")
    else
      echo "  consent fallback: disabled"
    fi
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