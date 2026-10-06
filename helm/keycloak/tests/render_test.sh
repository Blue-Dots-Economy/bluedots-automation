#!/usr/bin/env bash
# Render assertions for the keycloak chart that `helm lint` cannot express:
# which OTP delivery env reaches the container for each provider setting.
#
# Email OTP and SMS OTP pick their transport independently
# (otpEmailProvider, smsProvider). Either one on `http` needs the shared
# notification-service connection (SMS_HTTP_* plus the SMS_HTTP_SECRET key),
# so that block follows "either is http", not smsProvider alone.
set -euo pipefail
cd "$(dirname "$0")"
UMBRELLA=".."
TPL="../../../opentofu/aws/template"
NS_URL='http://signals-notification-service.signals.svc.cluster.local:3000/v1/notify'
fail() { echo "FAIL: $*" >&2; exit 1; }
# Chart defaults only (smsProvider: log, otpEmailProvider: smtp).
render() {
  helm template keycloak "$UMBRELLA" --namespace common-services \
    --set global.existingSecret=ci-smoke --set global.keycloakRealm=ci-smoke \
    --show-only charts/keycloak/templates/configmap.yaml \
    --show-only charts/keycloak/templates/deployment.yaml "$@"
}
# The way a cluster renders it: the template env's values (smsProvider: msg91).
cluster() {
  render -f ../../global-resources.yaml -f "$TPL/global-images.yaml" -f "$TPL/global-values.yaml" "$@"
}
has() { grep -qF -- "$1" <<<"$out"; }

# default: Keycloak keeps sending email OTP over the realm's SMTP server. The
# plugin picks smtp by provider order, so no email-provider env renders at all.
out="$(render)"
has 'KC_SPI_OTP_EMAIL' && fail "default renders an email OTP provider env"
has 'SMS_HTTP_URL' && fail "default renders the NS connection with nothing on http"
has 'KC_SPI_SMS_PROVIDER: "log"' || fail "default smsProvider is not log"

# an explicit smtp renders the same as the default
out="$(render --set keycloak.otpEmailProvider=smtp)"
has 'KC_SPI_OTP_EMAIL' && fail "otpEmailProvider=smtp renders an email OTP provider env"

# email over http on its own: provider env, the full NS block and its secret,
# while SMS stays on its vendor
out="$(cluster --set keycloak.otpEmailProvider=http)"
has 'KC_SPI_OTP_EMAIL__PROVIDER: "http"' || fail "otpEmailProvider=http does not render KC_SPI_OTP_EMAIL__PROVIDER=http"
has 'KC_SPI_SMS_PROVIDER: "msg91"' || fail "email over http changed the SMS provider"
has "SMS_HTTP_URL: \"$NS_URL\"" || fail "email over http lacks SMS_HTTP_URL on /v1/notify"
has 'SMS_HTTP_KEY_ID: "keycloak"' || fail "email over http lacks SMS_HTTP_KEY_ID"
has 'SMS_HTTP_TIMEOUT_MS: "5000"' || fail "email over http lacks SMS_HTTP_TIMEOUT_MS"
has 'key: SMS_HTTP_SECRET' || fail "email over http lacks the SMS_HTTP_SECRET secret ref"

# SMS over http still renders the NS block, and email stays on smtp
out="$(render --set keycloak.smsProvider=http)"
has 'KC_SPI_SMS_PROVIDER: "http"' || fail "smsProvider=http not rendered"
has "SMS_HTTP_URL: \"$NS_URL\"" || fail "default NS URL is not /v1/notify"
has 'SMS_HTTP_TEMPLATE_ID: "login_otp"' || fail "smsProvider=http lacks SMS_HTTP_TEMPLATE_ID"
has 'SMS_HTTP_OTP_VAR_NAME: "message"' || fail "smsProvider=http lacks SMS_HTTP_OTP_VAR_NAME"
has 'SMS_HTTP_KEY_ID: "keycloak"' || fail "smsProvider=http lacks SMS_HTTP_KEY_ID"
has 'key: SMS_HTTP_SECRET' || fail "smsProvider=http lacks the SMS_HTTP_SECRET secret ref"
has 'KC_SPI_OTP_EMAIL' && fail "smsProvider=http alone moved email OTP off smtp"

# both on http share the one connection, rendered once
out="$(render --set keycloak.smsProvider=http --set keycloak.otpEmailProvider=http)"
[ "$(grep -c 'SMS_HTTP_URL:' <<<"$out")" = 1 ] || fail "NS connection not rendered exactly once"
has 'KC_SPI_OTP_EMAIL__PROVIDER: "http"' || fail "both on http: email provider not rendered"

# the URL follows the signals release/namespace and an explicit override
out="$(render --set keycloak.otpEmailProvider=http --set global.signalsNamespace=sig2 --set global.signalsRelease=rel2)"
has 'SMS_HTTP_URL: "http://rel2-notification-service.sig2.svc.cluster.local:3000/v1/notify"' \
  || fail "NS URL does not follow global.signalsRelease/signalsNamespace"
out="$(render --set keycloak.otpEmailProvider=http --set keycloak.smsHttp.url=http://ns.test/v1/notify)"
has 'SMS_HTTP_URL: "http://ns.test/v1/notify"' || fail "smsHttp.url override not honoured"

# an unknown email transport stops the render instead of crash-looping Keycloak
if render --set keycloak.otpEmailProvider=sendgrid >/dev/null 2>&1; then
  fail "rendered with an unknown otpEmailProvider"
fi

# http OTP needs the NS signing secret. With the chart rendering its own Secret
# (no global.existingSecret), a blank smsHttpSecret stops the render instead of
# deploying a Keycloak whose every http OTP send is unsigned.
SECRET_SETS=()
for k in kcBootstrapAdminPassword keycloakPostgresPassword keycloakAdminClientSecret oidcClientSecret \
  signalsApiSecret signalstackClientSecret voiceDpgSignalsSecret campaignManagerSecret; do
  SECRET_SETS+=(--set "secrets.$k=rt-$k")
done
own() {
  helm template keycloak "$UMBRELLA" --namespace common-services \
    --set global.keycloakRealm=ci-smoke "${SECRET_SETS[@]}" --show-only templates/secrets.yaml "$@"
}
own >/dev/null || fail "default with its own Secret does not render"
for tr in smsProvider otpEmailProvider; do
  if own --set keycloak.$tr=http >/dev/null 2>&1; then fail "$tr=http rendered without smsHttpSecret"; fi
  if own --set keycloak.$tr=http --set 'secrets.smsHttpSecret= ' >/dev/null 2>&1; then
    fail "$tr=http rendered with a whitespace-only smsHttpSecret"
  fi
  out="$(own --set keycloak.$tr=http --set secrets.smsHttpSecret=rt-sign)"
  has 'SMS_HTTP_SECRET: "rt-sign"' || fail "$tr=http with a secret does not render SMS_HTTP_SECRET"
  render --set keycloak.$tr=http >/dev/null || fail "$tr=http with global.existingSecret does not render"
done
err="$(own --set keycloak.otpEmailProvider=http 2>&1 >/dev/null || true)"
grep -q 'signing secret' <<<"$err" || fail "blank-secret failure does not name the signing secret: $err"
echo "keycloak render_test: ok"
