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
echo "render_test: ok"
