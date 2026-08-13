#!/usr/bin/env bash
# Assert the properties this repo's deployment realm MUST hold.
#
# Self-contained on purpose: no network, no app-repo checkout, no pinned ref.
# The app repos' infra/keycloak/ trees are independent developer-local setups
# (see the plan's §3.1), so a "drift from upstream" diff would be wrong — it
# would fail on the deliberate hardening differences. What matters is not that
# this file matches something else, but that it satisfies the invariants below.
#
# Usage: scripts/assert-realm.sh [path-to-realm.json]
# Exit:  0 all assertions pass, 1 otherwise (prints every failure, not just the first)

set -uo pipefail

REALM_FILE="${1:-helm/keycloak/charts/keycloak/files/realm.json}"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -f "$REALM_FILE" ] || { echo "error: realm file not found: $REALM_FILE" >&2; exit 1; }

FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }

q() { jq -r "$1" "$REALM_FILE"; }

echo "Asserting realm: $REALM_FILE"

# ── A1. No dev-host entries anywhere ─────────────────────────────────────────
# The highest-value check: it is a security property (a production client's
# redirect / post-logout / CORS allow-lists) and it is completely invisible in a
# working deployment. Covers the ##-delimited post.logout.redirect.uris
# attribute as well as the JSON arrays, because that one is easy to miss.
local_hits=$(q '[paths(type=="string" and test("localhost|127\\.0\\.0\\.1")) | join(".")] | .[]' 2>/dev/null)
if [ -z "$local_hits" ]; then
  pass "no localhost/127.0.0.1 in any client URL, origin or logout allow-list"
else
  fail "dev host reachable in production realm at these paths:"
  printf '           %s\n' $local_hits
fi

# ── A2. Exactly the two service accounts, no test fixtures ───────────────────
# The realm this replaced shipped `testuser` and `alice` into real environments.
users=$(q '[.users[]?.username] | sort | join(",")')
if [ "$users" = "service-account-aggregator-api,service-account-signals-api" ]; then
  pass "users are exactly the two service accounts"
else
  fail "unexpected users (test fixtures?): $users"
fi

# ── A3. All three realm roles ────────────────────────────────────────────────
# org_owner is load-bearing: org approval calls assignRealmRole(sub,'org_owner')
# and the realm this replaced had NO realm roles at all.
for role in org_owner signals_participant signals_admin; do
  if [ "$(q --arg r "$role" '[.roles.realm[]?.name] | index($r) != null' 2>/dev/null)" = "true" ] \
     || jq -e --arg r "$role" '[.roles.realm[]?.name] | index($r) != null' "$REALM_FILE" >/dev/null; then
    pass "realm role present: $role"
  else
    fail "realm role MISSING: $role"
  fi
done

# ── A4. All seven clients, both DPGs ─────────────────────────────────────────
for client in aggregator-portal aggregator-api aggregator-bff \
              signals-ui signals-api aggregator-dpg voice-dpg; do
  if jq -e --arg c "$client" '[.clients[].clientId] | index($c) != null' "$REALM_FILE" >/dev/null; then
    pass "client present: $client"
  else
    fail "client MISSING: $client"
  fi
done

# ── A5. Per-client login theme override ──────────────────────────────────────
# This is what lets ONE shared realm serve two brands. Without it, signals users
# silently get the aggregator-branded login page — cosmetic but very visible.
theme=$(q '.clients[] | select(.clientId=="signals-ui") | .attributes."login_theme" // "unset"')
if [ "$theme" = "signals" ]; then
  pass "signals-ui carries login_theme=signals"
else
  fail "signals-ui login_theme is '$theme', expected 'signals'"
fi

# ── A6. The entitlement gate is scoped to the portal, and only the portal ────
# Too few bindings = the gate fell off aggregator-portal. Too many = it leaked
# onto another client's login path, e.g. signals'.
gated=$(q '[.clients[] | select((.authenticationFlowBindingOverrides // {}) != {}) | .clientId] | join(",")')
if [ "$gated" = "aggregator-portal" ]; then
  pass "flow-binding override on aggregator-portal only"
else
  fail "expected flow-binding override on aggregator-portal only, found: '${gated:-none}'"
fi

# ── A7. Realm name stays templated ───────────────────────────────────────────
# render-realm.sh substitutes it from KEYCLOAK_REALM. A literal here would
# hardcode the realm name and break the per-instance naming rule.
realm_name=$(q '.realm')
if [ "$realm_name" = "__KEYCLOAK_REALM__" ]; then
  pass "realm name is templated (__KEYCLOAK_REALM__)"
else
  fail "realm name is hardcoded to '$realm_name'"
fi

# ── A8. HTTPS required for external callers ──────────────────────────────────
# `external` not `all`: private (in-cluster) source addresses stay exempt so the
# keycloak-init Job can talk plain HTTP over the service URL.
ssl=$(q '.sslRequired')
if [ "$ssl" = "external" ]; then
  pass "sslRequired=external"
else
  fail "sslRequired is '$ssl', expected 'external'"
fi

# ── A9. Every placeholder is one render-realm.sh knows how to substitute ─────
# A stray placeholder is a deploy-time hard failure (render-realm.sh fails on
# unset vars). Catching it here turns that into a CI failure instead.
KNOWN='__KEYCLOAK_REALM__ __PUBLIC_BASE_URL__ __BRAND_LONG_NAME__
__AGGREGATOR_API_SECRET__ __AGGREGATOR_PORTAL_SECRET__ __AGGREGATOR_BFF_SECRET__
__SIGNALS_API_SECRET__ __SIGNALSTACK_CLIENT_SECRET__ __VOICE_DPG_SIGNALS_SECRET__
__SMTP_HOST__ __SMTP_PORT__ __SMTP_FROM__ __SMTP_FROM_DISPLAY__ __SMTP_AUTH__
__SMTP_SSL__ __SMTP_STARTTLS__ __SMTP_USER__ __SMTP_PASSWORD__'
unknown=""
for ph in $(grep -o '__[A-Z0-9_]*__' "$REALM_FILE" | sort -u); do
  case " $(echo $KNOWN) " in *" $ph "*) ;; *) unknown="$unknown $ph" ;; esac
done
if [ -z "$unknown" ]; then
  pass "all placeholders are known to render-realm.sh"
else
  fail "unknown placeholder(s), render will fail at deploy:$unknown"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "realm assertions: ALL PASSED"
else
  echo "realm assertions: FAILURES ABOVE — see docs/superpowers/plans/2026-08-04-keycloak-common-service.md §5.2/§10"
fi
exit "$FAILED"
