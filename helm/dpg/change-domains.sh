#!/usr/bin/env bash
# change-domains.sh — full domain cutover for signal-stack + aggregator.
#
# Mirrors the manual runbook:
#   repo values edit -> helm upgrade -> pod restart -> DB instance_url
#   migration -> Keycloak portal-client URI patch -> verify.
#
# NOTE: this handles the OIDC client redirect/logout URIs (mandatory — the
# realm is import-once, so helm alone leaves them on the old domain and login
# breaks with "Invalid redirect URI"). The Keycloak *login theme logo* is a
# separate concern (rebuild the aggregator-kc-theme image) and is NOT here.
#
# Usage:  edit the VARS block, then:  ./change-domains.sh
# Idempotent; safe to re-run.
set -euo pipefail

# ── VARS (edit these) ───────────────────────────────────────────────────────
SIGNALS_OLD="dpg.servehalflife.com"
SIGNALS_NEW="signals-purpledots.bluedotseconomy.org"
AGG_OLD="purpledots.servehalflife.com"
AGG_NEW="aggregators-purpledots.bluedotseconomy.org"

DPG_REPO="$HOME/Desktop/onest/dpg-monorepo"
AGG_REPO="$HOME/Desktop/onest/aggregator-dpg"
SS_NS="signal-stack"
AGG_NS="aggregator"
KC_ADMIN_USER="admin"
# ────────────────────────────────────────────────────────────────────────────

DPG_VALUES="$DPG_REPO/helmcharts/dpg/values.yaml"
AGG_VALUES="$AGG_REPO/helm/aggregator-dpg/values.yaml"
AGG_PURPLE="$AGG_REPO/helm/aggregator-dpg/values-purple.yaml"

echo "==> 0. DNS sanity — new domains must resolve before cutover"
for d in "$SIGNALS_NEW" "$AGG_NEW"; do
  getent hosts "$d" >/dev/null || { echo "FATAL: $d does not resolve to the ingress LB yet"; exit 1; }
done

echo "==> 1. rewrite repo values (old -> new), every occurrence"
sed -i "s|${SIGNALS_OLD}|${SIGNALS_NEW}|g" "$DPG_VALUES"
sed -i "s|${AGG_OLD}|${AGG_NEW}|g" "$AGG_VALUES" "$AGG_PURPLE"
echo "   remaining old refs (should be empty):"
grep -rn "$SIGNALS_OLD" "$DPG_VALUES" || true
grep -rn "$AGG_OLD" "$AGG_VALUES" "$AGG_PURPLE" || true

echo "==> 2. signal-stack helm upgrade + restart"
helm upgrade dpg "$DPG_REPO/helmcharts/dpg" -n "$SS_NS" -f "$DPG_VALUES"
kubectl -n "$SS_NS" rollout restart deploy/dpg-api deploy/dpg-ui
kubectl -n "$SS_NS" rollout status deploy/dpg-api --timeout=180s

echo "==> 3. migrate baked instance_urls in Postgres (items + actions + events)"
PGPW=$(kubectl -n "$SS_NS" get secret dpg-postgres -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl -n "$SS_NS" exec dpg-postgresql-0 -- env PGPASSWORD="$PGPW" psql -U postgres -d dpg -c "
BEGIN;
UPDATE items         SET item_instance_url       ='https://${SIGNALS_NEW}' WHERE item_instance_url       ='https://${SIGNALS_OLD}';
UPDATE item_actions  SET source_item_instance_url='https://${SIGNALS_NEW}' WHERE source_item_instance_url='https://${SIGNALS_OLD}';
UPDATE item_actions  SET target_item_instance_url='https://${SIGNALS_NEW}' WHERE target_item_instance_url='https://${SIGNALS_OLD}';
UPDATE action_events SET source_item_instance_url='https://${SIGNALS_NEW}' WHERE source_item_instance_url='https://${SIGNALS_OLD}';
UPDATE action_events SET target_item_instance_url='https://${SIGNALS_NEW}' WHERE target_item_instance_url='https://${SIGNALS_OLD}';
UPDATE action_events SET origin_instance_domain  ='https://${SIGNALS_NEW}' WHERE origin_instance_domain  ='https://${SIGNALS_OLD}';
COMMIT;"

echo "==> 4. aggregator helm upgrade + restart"
helm upgrade aggregator "$AGG_REPO/helm/aggregator-dpg" -n "$AGG_NS" \
  -f "$AGG_VALUES" -f "$AGG_PURPLE"
kubectl -n "$AGG_NS" rollout restart deploy/aggregator-api deploy/aggregator-web deploy/aggregator-worker
kubectl -n "$AGG_NS" rollout status deploy/aggregator-web --timeout=180s

echo "==> 5. wait for new TLS certs"
kubectl -n "$SS_NS"  wait --for=condition=Ready certificate --all --timeout=300s || true
kubectl -n "$AGG_NS" wait --for=condition=Ready certificate --all --timeout=300s || true

echo "==> 6. patch Keycloak portal client (realm is import-once; helm won't update it)"
KCPW=$(kubectl -n "$AGG_NS" get secret aggregator-secrets -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)
B="https://${AGG_NEW}/auth"
TOK=$(curl -sk -X POST "$B/realms/master/protocol/openid-connect/token" \
      -d "username=${KC_ADMIN_USER}&password=${KCPW}&grant_type=password&client_id=admin-cli" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
CID=$(curl -sk -H "Authorization: Bearer $TOK" \
      "$B/admin/realms/aggregator/clients?clientId=aggregator-portal" \
      | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
curl -sk -H "Authorization: Bearer $TOK" "$B/admin/realms/aggregator/clients/$CID" > /tmp/_portal.json
NEW="https://${AGG_NEW}" python3 - <<'PY'
import json, os
NEW = os.environ['NEW']
c = json.load(open('/tmp/_portal.json'))
c['redirectUris'] = [
    "http://localhost:3000/api/auth/callback",
    "http://localhost:3100/api/auth/callback",
    "http://localhost/api/auth/callback",
    f"{NEW}/api/auth/callback",
]
c['webOrigins'] = ["http://localhost:3000", "http://localhost:3100", "http://localhost", NEW]
c.setdefault('attributes', {})['post.logout.redirect.uris'] = "##".join([
    "http://localhost:3000/", "http://localhost:3000/login",
    "http://localhost:3100/", "http://localhost:3100/login",
    "http://localhost/", "http://localhost/login",
    f"{NEW}/", f"{NEW}/login",
])
json.dump(c, open('/tmp/_portal.json', 'w'))
PY
curl -sk -X PUT -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  --data @/tmp/_portal.json "$B/admin/realms/aggregator/clients/$CID" -w "   KC client PUT: HTTP %{http_code}\n"
rm -f /tmp/_portal.json

echo "==> 7. verify"
for u in "https://${SIGNALS_NEW}/" "https://${AGG_NEW}/"; do
  echo "   $u -> $(curl -s -o /dev/null -w '%{http_code} cert=%{ssl_verify_result}' --max-time 15 "$u")"
done
echo "DONE. Commit the values.yaml edits separately."
