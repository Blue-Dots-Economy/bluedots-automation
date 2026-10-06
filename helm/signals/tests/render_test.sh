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
trap 'restore; restore_fixtures' EXIT
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
grep -q 'consent.json' <<<"$apiw" || fail "Signals lost consent.json"
grep -q "path: $FXB/consent.json" <<<"$apiw" || fail "Signals lost brand consent"
grep -q 'messages.properties' <<<"$apiw" && fail "Signals still gets messages.properties"
grep -q 'sms.properties' <<<"$apiw" && fail "Signals still gets sms.properties"
signals() {
  helm template signals .. --namespace signals -f ../../global-resources.yaml \
    -f "$TPL/global-images.yaml" -f "$TPL/global-values.yaml" \
    --set-json 'api.schemas.networks=[]' --set ui.reference.enabled=false \
    --set notification-service.postgres.host=ci-smoke.invalid "$@"
}
api="$(signals --show-only charts/api/templates/secret.yaml --show-only charts/api/templates/configmap.yaml)"
grep -q 'NOTIFICATION_SERVICE_SECRET' <<<"$api" && fail "Signals still gets the HMAC secret"
grep -q 'NOTIFICATION_SERVICE_KEY_ID' <<<"$api" && fail "Signals still gets the HMAC key id"
grep -q 'SMS_TEMPLATE_ID' <<<"$api" && fail "Signals still gets SMS_TEMPLATE_ID"
grep -q 'NOTIFICATION_FROM_EMAIL' <<<"$api" && fail "Signals still gets NOTIFICATION_FROM_EMAIL"
grep -q 'NOTIFICATION_SERVICE_ENDPOINT' <<<"$api" || fail "Signals lost NOTIFICATION_SERVICE_ENDPOINT"
grep -q 'KEYCLOAK_API_CLIENT_ID' <<<"$api" || fail "Signals lost KEYCLOAK_API_CLIENT_ID"
# Source values and the generated secrets carry none of the removed keys
for f in ../values.yaml ../charts/api/values.yaml "$TPL/global-values.yaml" \
  ../../../opentofu/aws/modules/output-file/global-secrets.yaml.tfpl; do
  if grep -nE 'NOTIFICATION_SERVICE_(KEY_ID|SECRET)|notification(KeyId|Secret)|SMS_TEMPLATE_ID|NOTIFICATION_FROM_EMAIL|[&*]notification_(key_id|secret)\b' "$f"; then
    fail "$f still carries a removed Signals notification key"
  fi
done
# Part A keeps dpg-api-client so old Signals pods keep delivering mid-rollout (F4-1)
ns="$(signals --show-only charts/notification-service/templates/internal-secret.yaml)"
grep -q 'dpg-api-client' <<<"$ns" || fail "Part A must keep dpg-api-client in internal-secrets"
grep -q '"dpg-api-client"' ../../../opentofu/aws/modules/output-file/global-secrets.yaml.tfpl \
  || fail "Part A must keep dpg-api-client in the generated internal-secrets"
echo "render_test: ok"
