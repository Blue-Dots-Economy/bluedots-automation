#!/usr/bin/env bash
# Render assertions for the notification-service subchart that `helm lint`
# cannot express: what renders when a fetched file is or is not on disk.
set -euo pipefail
cd "$(dirname "$0")"
CHART="../charts/notification-service"
CAT_DIR="$CHART/files/catalogue"
BASE=(--namespace signals --set config.SMTP_AWS_SES=true --set config.EMAIL_FROM_ADDRESS=from@example.test --set postgres.host=pg.test)
fail() { echo "FAIL: $*" >&2; exit 1; }
render() { helm template ns "$CHART" "${BASE[@]}" "$@"; }

backup=""
if [ -f "$CAT_DIR/ns-catalogue.json" ]; then backup="$(mktemp)"; cp "$CAT_DIR/ns-catalogue.json" "$backup"; fi
restore() {
  rm -f "$CAT_DIR/ns-catalogue.json"
  if [ -n "$backup" ]; then cp "$backup" "$CAT_DIR/ns-catalogue.json"; rm -f "$backup"; fi
}
trap restore EXIT

# no file: no ConfigMap, no mount, no NS_SEED_FILE
rm -f "$CAT_DIR/ns-catalogue.json"
out="$(render)"
grep -q 'ns-catalogue.json' <<<"$out" && fail "catalogue rendered without a file"
grep -q 'NS_SEED_FILE' <<<"$out" && fail "NS_SEED_FILE set without a file"
grep -q 'mountPath: /app/seed' <<<"$out" && fail "/app/seed mounted without a file"

# file present: ConfigMap, mount, env, checksum
mkdir -p "$CAT_DIR"
printf '{"version":"t1","templates":[],"policies":[]}' > "$CAT_DIR/ns-catalogue.json"
out="$(render)"
grep -q 'name: ns-dpg-notification-service-catalogue' <<<"$out" || fail "no catalogue ConfigMap"
grep -q 'NS_SEED_FILE: "/app/seed/ns-catalogue.json"' <<<"$out" || fail "NS_SEED_FILE missing"
grep -q 'mountPath: /app/seed' <<<"$out" || fail "/app/seed not mounted"
sum1="$(grep 'checksum/catalogue' <<<"$out")" || fail "no checksum/catalogue"

# checksum follows the file
printf '{"version":"t2","templates":[],"policies":[]}' > "$CAT_DIR/ns-catalogue.json"
sum2="$(render | grep 'checksum/catalogue')"
[ "$sum1" != "$sum2" ] || fail "checksum did not change with the file"

# render fails without EMAIL_FROM_ADDRESS (every v1 email would fail permanently)
if helm template ns "$CHART" --namespace signals --set config.SMTP_AWS_SES=true --set postgres.host=pg.test >/dev/null 2>&1; then
  fail "rendered without EMAIL_FROM_ADDRESS"
fi
if helm template ns "$CHART" --namespace signals --set config.SMTP_AWS_SES=true --set postgres.host=pg.test --set 'config.EMAIL_FROM_ADDRESS= ' >/dev/null 2>&1; then
  fail "rendered with a whitespace-only EMAIL_FROM_ADDRESS"
fi
out="$(render --set config.EMAIL_FROM_NAME='Blue Dots')"
grep -q 'EMAIL_FROM_ADDRESS: "from@example.test"' <<<"$out" || fail "EMAIL_FROM_ADDRESS not rendered"
grep -q 'EMAIL_FROM_NAME: "Blue Dots"' <<<"$out" || fail "EMAIL_FROM_NAME not rendered"

# the umbrella wires the sender from the cluster's SMTP anchors, and a cluster
# values file layered later can give NS its own From name (e.g. "UP SDM")
TPL="../../../opentofu/aws/template"
umbrella() {
  helm template signals .. --namespace signals -f ../../global-resources.yaml \
    -f "$TPL/global-images.yaml" -f "$TPL/global-values.yaml" \
    --set-json 'api.schemas.networks=[]' --set ui.reference.enabled=false \
    --set notification-service.postgres.host=ci-smoke.invalid \
    --show-only charts/notification-service/templates/configmap.yaml "$@"
}
out="$(umbrella)"
grep -q 'EMAIL_FROM_ADDRESS: "sender@example.com"' <<<"$out" || fail "umbrella EMAIL_FROM_ADDRESS is not the smtp_user anchor"
grep -q 'EMAIL_FROM_NAME: "Blue Dots"' <<<"$out" || fail "umbrella EMAIL_FROM_NAME is not the smtp_from_display anchor"
grep -q 'SMTP_FROM: "sender@example.com"' <<<"$out" || fail "umbrella SMTP_FROM differs from EMAIL_FROM_ADDRESS"
cluster_values="$(mktemp)"
printf 'notification-service:\n  config:\n    EMAIL_FROM_NAME: "UP SDM"\n' > "$cluster_values"
out="$(umbrella -f "$cluster_values")"
rm -f "$cluster_values"
grep -q 'EMAIL_FROM_NAME: "UP SDM"' <<<"$out" || fail "cluster values cannot override EMAIL_FROM_NAME"

# Signals reaches NS with its Keycloak signals-api client: no HMAC pair, no
# SMS template id, no from-address, and no in-app email/SMS copy files. Copy
# lives in notification-service, seeded from the cluster's catalogue.
# Fixture files carry a name no network uses, and only they are removed on exit.
API_FILES="../charts/api/files"
FX=rtfx; FXB=rtbrand
fx_files=("networks/$FX.json" "consent/$FX.json" "consent/$FX.$FXB.json"
  "messages/$FX.properties" "messages/$FX.$FXB.properties"
  "sms/$FX.properties" "sms/$FX.$FXB.properties")
fx_new_dirs=()
for d in networks consent messages sms; do
  [ -d "$API_FILES/$d" ] || { mkdir -p "$API_FILES/$d"; fx_new_dirs+=("$API_FILES/$d"); }
done
restore_fixtures() {
  for f in "${fx_files[@]}"; do rm -f "${API_FILES:?}/$f"; done
  for d in "${fx_new_dirs[@]+"${fx_new_dirs[@]}"}"; do rmdir "$d" 2>/dev/null || true; done
}
secrets_values=""
trap 'restore; restore_fixtures; rm -f "$secrets_values"' EXIT
printf '{"id":"%s"}' "$FX" > "$API_FILES/networks/$FX.json"
printf '{"documents":{}}' > "$API_FILES/consent/$FX.json"
printf '{"documents":{}}' > "$API_FILES/consent/$FX.$FXB.json"
# stale copy files on disk must not resurrect the delivery
for f in messages/$FX.properties messages/$FX.$FXB.properties sms/$FX.properties sms/$FX.$FXB.properties; do
  printf 'k=v\n' > "$API_FILES/$f"
done
apiw="$(helm template a ../charts/api --set global.publicHost=x.test \
  --set-json "schemas.networks=[\"$FX\"]" --set schemas.consentNetwork=$FX --set schemas.consentBrand=$FXB \
  --show-only templates/schemas-configmap.yaml --show-only templates/deployment.yaml)"
grep -q '^  consent.json: |' <<<"$apiw" || fail "Signals lost the consent.json ConfigMap key"
grep -q "path: $FXB/consent.json" <<<"$apiw" || fail "Signals lost brand consent"
grep -q 'messages.properties' <<<"$apiw" && fail "Signals still gets messages.properties"
grep -q 'sms.properties' <<<"$apiw" && fail "Signals still gets sms.properties"
signals() {
  helm template signals .. --namespace signals -f ../../global-resources.yaml \
    -f "$TPL/global-images.yaml" -f "$TPL/global-values.yaml" \
    --set-json 'api.schemas.networks=[]' --set ui.reference.enabled=false \
    --set notification-service.postgres.host=ci-smoke.invalid "$@"
}
# The generated secrets file, placeholders filled, layered the way a deploy
# layers it; signals_notification_secret gets a value of its own.
TFPL=../../../opentofu/aws/modules/output-file/global-secrets.yaml.tfpl
secrets_values="$(mktemp)"
sed -E -e 's/\$\{yamlencode\([^}]*\)\}/"x"/' -e 's/\$\{signals_notification_secret\}/rt-ns-secret/g' \
  -e 's/\$\{sms_http_secret\}/rt-kc-sign/g' -e 's/\$\{ns_admin_secret\}/rt-ns-admin/g' \
  -e 's/\$\{[a-z0-9_]+\}/x/g' "$TFPL" > "$secrets_values"
api="$(signals -f "$secrets_values" --show-only charts/api/templates/secret.yaml --show-only charts/api/templates/configmap.yaml)"
ns="$(signals -f "$secrets_values" --show-only charts/notification-service/templates/internal-secret.yaml)"
grep -q 'SMS_TEMPLATE_ID' <<<"$api" && fail "Signals still gets SMS_TEMPLATE_ID"
grep -q 'NOTIFICATION_SERVICE_ENDPOINT' <<<"$api" || fail "Signals lost NOTIFICATION_SERVICE_ENDPOINT"
grep -q 'KEYCLOAK_API_CLIENT_ID' <<<"$api" || fail "Signals lost KEYCLOAK_API_CLIENT_ID"
# Present until Part B: the previous Signals image reads the HMAC pair and the
# From address through envFrom, so they ride along for rollout and rollback,
# and the pair matches the NS dpg-api-client entry.
grep -q 'NOTIFICATION_SERVICE_KEY_ID: "dpg-api-client"' <<<"$api" || fail "HMAC key id must stay until Part B"
grep -q 'NOTIFICATION_SERVICE_SECRET: "rt-ns-secret"' <<<"$api" || fail "HMAC secret must stay until Part B"
grep -q 'NOTIFICATION_FROM_EMAIL: "sender@example.com"' <<<"$api" || fail "NOTIFICATION_FROM_EMAIL must stay until Part B"
tr -d ' \n' <<<"$ns" | grep -q '"dpg-api-client":{"secret":"rt-ns-secret"}' \
  || fail "NS dpg-api-client must carry the Signals HMAC secret until Part B"
# The operator key for the NS admin API (/v1/admin/*, /failed/retry): its own
# generated secret, admin scope only. Keycloak's entry keeps the send default.
ns_json="$(python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Secret":
        print(d["stringData"]["internal-secrets.json"])' <<<"$ns")"
jq -e '."ns-admin" == {"secret": "rt-ns-admin", "scopes": ["templates:admin"]}' <<<"$ns_json" >/dev/null \
  || fail "NS internal secrets lack ns-admin with scopes [templates:admin]: $ns_json"
jq -e '.keycloak == {"secret": "rt-kc-sign"}' <<<"$ns_json" >/dev/null \
  || fail "NS keycloak entry is not the sms_http_secret send key: $ns_json"
jq -e 'has("dpg-api-client")' <<<"$ns_json" >/dev/null || fail "NS lost dpg-api-client: $ns_json"
# Source values carry no SMS_TEMPLATE_ID, and keep the HMAC pair until Part B
for f in ../values.yaml ../charts/api/values.yaml "$TPL/global-values.yaml" "$TFPL"; do
  if grep -n 'SMS_TEMPLATE_ID' "$f"; then fail "$f still carries SMS_TEMPLATE_ID"; fi
done
grep -q 'NOTIFICATION_SERVICE_KEY_ID: \*notification_key_id' ../values.yaml || fail "umbrella HMAC key id must stay until Part B"
grep -q 'NOTIFICATION_SERVICE_SECRET: \*notification_secret' ../values.yaml || fail "umbrella HMAC secret must stay until Part B"
grep -q 'notificationKeyId: "dpg-api-client"' "$TPL/global-values.yaml" || fail "template notificationKeyId must stay until Part B"
grep -q 'notificationSecret: "${signals_notification_secret}"' "$TFPL" || fail "tfpl notificationSecret must stay until Part B"
# msg91_template_id -> SMS_LOGIN_OTP_TEMPLATE_ID: NS publishes login_otp from it
# once and never re-reads it, so the placeholder must never reach the ConfigMap.
grep -q 'SMS_LOGIN_OTP_TEMPLATE_ID: "${msg91_template_id}"' "$TFPL" || fail "tfpl no longer feeds SMS_LOGIN_OTP_TEMPLATE_ID from msg91_template_id"
grep -Eq 'msg91_template_id_raw += try\(local\.manual_secrets\.msg91_template_id, ""\)' ../../../opentofu/aws/_common/output-file.hcl \
  || fail "output-file msg91_template_id must default to \"\""
grep -q 'msg91_template_id_raw == "UPDATE_THIS_VALUE" ? ""' ../../../opentofu/aws/_common/output-file.hcl \
  || fail "output-file must render a leftover UPDATE_THIS_VALUE msg91_template_id as \"\""
out="$(render --set config.SMS_LOGIN_OTP_TEMPLATE_ID=UPDATE_THIS_VALUE)"
grep -q 'SMS_LOGIN_OTP_TEMPLATE_ID' <<<"$out" && fail "placeholder SMS_LOGIN_OTP_TEMPLATE_ID reached the ConfigMap"
out="$(render --set config.SMS_LOGIN_OTP_TEMPLATE_ID=)"
grep -q 'SMS_LOGIN_OTP_TEMPLATE_ID' <<<"$out" && fail "empty SMS_LOGIN_OTP_TEMPLATE_ID reached the ConfigMap"
out="$(render --set config.SMS_LOGIN_OTP_TEMPLATE_ID=flow-123)"
grep -q 'SMS_LOGIN_OTP_TEMPLATE_ID: "flow-123"' <<<"$out" || fail "a real SMS_LOGIN_OTP_TEMPLATE_ID was dropped"
# Part A keeps dpg-api-client so old Signals pods keep delivering mid-rollout (F4-1)
ns="$(signals --show-only charts/notification-service/templates/internal-secret.yaml)"
grep -q 'dpg-api-client' <<<"$ns" || fail "Part A must keep dpg-api-client in internal-secrets"
grep -q '"dpg-api-client"' ../../../opentofu/aws/modules/output-file/global-secrets.yaml.tfpl \
  || fail "Part A must keep dpg-api-client in the generated internal-secrets"
echo "render_test: ok"
