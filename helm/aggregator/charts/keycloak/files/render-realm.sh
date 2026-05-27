#!/bin/sh
# Renders realm JSON templates from /opt/keycloak/data/import-template into the
# import dir, substituting __PUBLIC_BASE_URL__ and the __SMTP_*__ placeholders
# with the matching env vars, then hands off to the upstream Keycloak entrypoint.
#
# Why a render step: Keycloak --import-realm does not perform env-var
# substitution on realm JSON. Hardcoding public hostnames/IPs or SMTP creds in
# the checked-in realm forces a code edit per environment. This script lets the
# same template boot on any VM by reading env values at container start.
set -eu

SRC_DIR="/opt/keycloak/data/import-template"
DST_DIR="/opt/keycloak/data/import"

: "${PUBLIC_BASE_URL:?PUBLIC_BASE_URL must be set (e.g. http://1.2.3.4 or https://portal.example.com)}"

# SMTP placeholders. Empty values are valid: when SMTP_AUTH=false, Keycloak
# ignores SMTP_USER/SMTP_PASSWORD even if they are empty strings.
: "${SMTP_HOST:=mailhog}"
: "${SMTP_PORT:=1025}"
: "${SMTP_FROM:=no-reply@bluedots.local}"
: "${SMTP_FROM_DISPLAY:=Blue Dots Aggregator}"
: "${SMTP_SSL:=false}"
: "${SMTP_STARTTLS:=false}"
: "${SMTP_AUTH:=false}"
: "${SMTP_USER:=}"
: "${SMTP_PASSWORD:=}"

mkdir -p "$DST_DIR"

# Escape sed replacement metacharacters (& and |) in any substituted value.
escape() {
  printf '%s' "$1" | sed -e 's/[&|]/\\&/g'
}

PUBLIC_BASE_URL_ESC=$(escape "$PUBLIC_BASE_URL")
SMTP_HOST_ESC=$(escape "$SMTP_HOST")
SMTP_PORT_ESC=$(escape "$SMTP_PORT")
SMTP_FROM_ESC=$(escape "$SMTP_FROM")
SMTP_FROM_DISPLAY_ESC=$(escape "$SMTP_FROM_DISPLAY")
SMTP_SSL_ESC=$(escape "$SMTP_SSL")
SMTP_STARTTLS_ESC=$(escape "$SMTP_STARTTLS")
SMTP_AUTH_ESC=$(escape "$SMTP_AUTH")
SMTP_USER_ESC=$(escape "$SMTP_USER")
SMTP_PASSWORD_ESC=$(escape "$SMTP_PASSWORD")

for src in "$SRC_DIR"/*.json; do
  [ -f "$src" ] || continue
  dst="$DST_DIR/$(basename "$src")"
  sed \
    -e "s|__PUBLIC_BASE_URL__|${PUBLIC_BASE_URL_ESC}|g" \
    -e "s|__SMTP_HOST__|${SMTP_HOST_ESC}|g" \
    -e "s|__SMTP_PORT__|${SMTP_PORT_ESC}|g" \
    -e "s|__SMTP_FROM__|${SMTP_FROM_ESC}|g" \
    -e "s|__SMTP_FROM_DISPLAY__|${SMTP_FROM_DISPLAY_ESC}|g" \
    -e "s|__SMTP_SSL__|${SMTP_SSL_ESC}|g" \
    -e "s|__SMTP_STARTTLS__|${SMTP_STARTTLS_ESC}|g" \
    -e "s|__SMTP_AUTH__|${SMTP_AUTH_ESC}|g" \
    -e "s|__SMTP_USER__|${SMTP_USER_ESC}|g" \
    -e "s|__SMTP_PASSWORD__|${SMTP_PASSWORD_ESC}|g" \
    "$src" > "$dst"
  echo "rendered $(basename "$src") -> $dst (PUBLIC_BASE_URL=$PUBLIC_BASE_URL, SMTP=$SMTP_HOST:$SMTP_PORT auth=$SMTP_AUTH)"
done

exec /opt/keycloak/bin/kc.sh "$@"
