#!/bin/bash
# One-time fill of the random passwords in global-secrets.yaml (the ones opentofu's
# random_passwords module generates on AWS). Only EMPTY values are filled, so a re-run
# never rotates anything; keys sharing one secret get the same value.
#   ./generate-passwords.sh [file]     # default: global-secrets.yaml, created from the example if missing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$SCRIPT_DIR/global-secrets.yaml}"
EXAMPLE="$SCRIPT_DIR/global-secrets.example.yaml"

# <yaml path> <secret> — one secret may feed several paths.
MAP='
credentials.dpgPassword                                  signals_postgres_password
credentials.postgresql.password                          signals_postgres_password
api.secrets.data.POSTGRES_PASSWORD                       signals_postgres_password
search.secrets.data.POSTGRES_PASSWORD                    signals_postgres_password
credentials.keycloakPassword                             keycloak_postgres_password
secrets.keycloakPostgresPassword                         keycloak_postgres_password
credentials.aggregatorPassword                           aggregator_postgres_password
credentials.aggregatorExportRoPassword                   aggregator_export_ro_password
credentials.campaignManagerSignalsRoPassword             campaign_manager_signals_ro_password
credentials.redisPassword                                signals_redis_password
credentials.redis.password                               signals_redis_password
secrets.redisPassword                                    signals_redis_password
api.secrets.data.REDIS_PASSWORD                          signals_redis_password
search.secrets.data.REDIS_PASSWORD                       signals_redis_password
prometheus.grafana.adminPassword                         monitoring_grafana_password
secrets.kcBootstrapAdminPassword                         aggregator_kc_bootstrap_admin_password
secrets.keycloakAdminClientSecret                        aggregator_keycloak_admin_client_secret
secrets.oidcClientSecret                                 aggregator_oidc_client_secret
secrets.signalsApiSecret                                 signals_api_client_secret
api.secrets.data.KEYCLOAK_API_CLIENT_SECRET              signals_api_client_secret
secrets.signalstackClientSecret                          signalstack_client_secret
secrets.voiceDpgSignalsSecret                            voice_dpg_signals_secret
secrets.campaignManagerSecret                            campaign_manager_secret
api.secrets.authSecret                                   signals_auth_secret
api.secrets.data.AUTH_SECRET                             signals_auth_secret
api.secrets.notificationSecret                           signals_notification_secret
api.secrets.data.NOTIFICATION_SERVICE_SECRET             signals_notification_secret
api.secrets.data.SIGNALS_PII_KEY                         signals_pii_key
api.secrets.data.INSTANCE_SHARED_SECRET                  signals_instance_shared_secret
api.secrets.data.AGGREGATOR_DPG_API_KEY                  signalstack_admin_key
api.secrets.data.SIGNALS_SEARCH_API_KEY                  signals_search_api_key
api.secrets.data.RAYA_VOICE_BOT_API_KEY                  raya_voice_bot_api_key
'

# Same shapes as random_passwords: hex = random_id (bytes), alnum = random_password (length).
spec() {
    case "$1" in
        keycloak_postgres_password) echo hex 24 ;;
        signals_postgres_password|aggregator_postgres_password|aggregator_export_ro_password|\
        campaign_manager_signals_ro_password|signals_redis_password|aggregator_kc_bootstrap_admin_password) echo hex 16 ;;
        monitoring_grafana_password) echo alnum 16 ;;
        signalstack_admin_key|signals_search_api_key|raya_voice_bot_api_key) echo alnum 48 ;;
        *) echo hex 32 ;;
    esac
}

gen() { # gen hex|alnum N
    if [[ "$1" == hex ]]; then
        od -An -tx1 -N"$2" /dev/urandom | tr -d ' \n'
    else
        (LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$2") || true
    fi
}

# Walks the YAML by indentation. mode=list prints "<path>\t<value>";
# mode=fill rewrites empty "" values from vals ("<path>\t<value>") and logs filled paths.
# Lines inside a block scalar (e.g. internalSecrets.json) match only the "<id>": { "secret": ... } form.
WALK='
BEGIN { blk = -1; n = 0
        if (mode == "fill") while ((getline l < vals) > 0) { split(l, a, "\t"); v[a[1]] = a[2] } }
function out(line) { if (mode == "fill") print line }
{
    line = $0
    if (line ~ /^[ \t]*($|#)/) { out(line); next }
    match(line, /^ */); ind = RLENGTH
    if (blk >= 0 && ind > blk) {
        if (match(line, /"[A-Za-z0-9_-]+": *\{ *"secret": *"[^"]*" *\}/)) {
            id = line; sub(/^[ \t]*"/, "", id); sub(/".*/, "", id); p = prefix "." id
            s = line; sub(/.*"secret": *"/, "", s); sub(/".*/, "", s)
            if (mode == "list") print p "\t" s
            else if (s == "" && (p in v)) { sub(/"secret": *""/, "\"secret\": \"" v[p] "\"", line); print p > logf }
        }
        out(line); next
    }
    blk = -1
    if (!match(line, /^ *[A-Za-z0-9_.-]+:/)) { out(line); next }
    key = substr(line, ind + 1); sub(/:.*/, "", key)
    rest = line; sub(/^ *[A-Za-z0-9_.-]+:[ \t]*/, "", rest)
    while (n > 0 && lvl[n] >= ind) n--
    n++; lvl[n] = ind; nm[n] = key
    p = nm[1]; for (i = 2; i <= n; i++) p = p "." nm[i]
    if (rest ~ /^[|>]/) { blk = ind; prefix = p; out(line); next }
    if (rest ~ /^"/) { val = substr(rest, 2); sub(/".*/, "", val) } else { val = rest; sub(/[ \t]+#.*/, "", val) }
    if (mode == "list") print p "\t" val
    else if (rest ~ /^""/ && (p in v)) { sub(/: *""/, ": \"" v[p] "\"", line); print p > logf }
    out(line)
}'

[[ -f "$OUT" ]] || { cp "$EXAMPLE" "$OUT"; echo "created $OUT from the example"; }
chmod 600 "$OUT"

declare -A secret_of value
while read -r p s; do [[ -n "$p" ]] && secret_of[$p]=$s; done <<< "$MAP"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
awk -v mode=list "$WALK" "$OUT" > "$work/current"

# Reuse a value already present for a secret, so its sibling keys stay identical.
missing=0
for p in "${!secret_of[@]}"; do
    v=$(awk -F'\t' -v p="$p" '$1 == p { print $2; exit }' "$work/current")
    grep -qF -- "$p"$'\t' "$work/current" || { echo "WARNING: $p not found in $OUT" >&2; missing=1; }
    s=${secret_of[$p]}
    [[ -n "$v" && -z "${value[$s]:-}" ]] && value[$s]=$v
done

for p in "${!secret_of[@]}"; do
    s=${secret_of[$p]}
    if [[ -z "${value[$s]:-}" ]]; then read -r kind len <<< "$(spec "$s")"; value[$s]=$(gen "$kind" "$len"); fi
    printf '%s\t%s\n' "$p" "${value[$s]}"
done > "$work/vals"

awk -v mode=fill -v vals="$work/vals" -v logf="$work/log" "$WALK" "$OUT" > "$work/out"
touch "$work/log"
cat "$work/out" > "$OUT"   # keeps the file's 600 mode

if [[ -s "$work/log" ]]; then
    echo "Filled $(wc -l < "$work/log") empty keys:"; sed 's/^/  /' "$work/log" | sort
else
    echo "Nothing to fill: every generated key already has a value."
fi
echo "Fill by hand: postgresAdminPassword, SMTP/MSG91/Google keys, smsHttpSecret, SSO_* and anything else still \"\"."
exit "$missing"
