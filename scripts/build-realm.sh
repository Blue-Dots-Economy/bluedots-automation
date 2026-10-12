#!/usr/bin/env bash
# Build this repo's deployment realm from an app repo's local-dev realm.
#
# WHY THIS EXISTS
# ---------------
# `infra/keycloak/` in aggregator-dpg and signals-dpg are independent
# DEVELOPER-LOCAL setups. They are not upstream of this repo. This repo owns the
# realm that reaches real environments, and that realm must differ from the
# local ones in specific, deliberate ways (localhost redirects removed, HTTPS
# required). So the deployment realm is BUILT from a local one by this
# transform — never copied verbatim.
#
# The merge itself needs no logic: the aggregator repo's local realm has been
# verified to be a strict superset of the signals one (all 7 clients, all 3
# realm roles, both service accounts, both login themes, and OTP flows that are
# execution-for-execution identical to signals'). So the source is that file,
# and the only work is the hardening transform below.
#
# Re-run this whenever either app repo changes its Keycloak setup in a way that
# affects deployment (new client, role, mapper, flow or theme). See
# docs/superpowers/plans/2026-08-04-keycloak-common-service.md §5.1/§5.2.
#
# Usage:
#   scripts/build-realm.sh <path-to-source-realm.json> [output]
#
# Example:
#   scripts/build-realm.sh ../aggregator-dpg/infra/keycloak/realms/realm.json
#
# After running, ALWAYS run scripts/assert-realm.sh on the output.

set -euo pipefail

SRC="${1:?usage: build-realm.sh <source realm.json> [output]}"
OUT="${2:-helm/keycloak/charts/keycloak/files/realm.json}"

[ -f "$SRC" ] || { echo "error: source realm not found: $SRC" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }

echo "[build-realm] source: $SRC"
echo "[build-realm] output: $OUT"

# ── The hardening transform ────────────────────────────────────────────────────
#
# H1  Strip localhost / 127.0.0.1 from every client's redirectUris, webOrigins
#     AND the `post.logout.redirect.uris` attribute. On a laptop these are the
#     point; in a real environment they widen a production OAuth client's
#     redirect allow-list, its post-logout allow-list and its CORS origins for no
#     benefit. Only the __PUBLIC_BASE_URL__ entries should survive.
#
#     Note `post.logout.redirect.uris` is a client ATTRIBUTE holding a single
#     `##`-delimited string, not a JSON array — it needs its own handling and is
#     easy to miss. Miss it and the localhost entries ship even though
#     redirectUris looks clean.
#
# H3  sslRequired: none -> external. `external` (not `all`) is deliberate:
#     Keycloak treats PRIVATE source addresses as exempt, so cluster-internal
#     plain-HTTP callers (the keycloak-init Job, and any pod using the in-cluster
#     service URL) keep working, while anything arriving from outside must be
#     HTTPS. Public traffic arrives via Kong over TLS and Keycloak sees it as
#     HTTPS because KC_PROXY_HEADERS=xforwarded is set.
#     Caveat: a `kubectl port-forward` session comes from a non-private source
#     address and will get 403 "HTTPS required" — expected, not a fault.
#
# H2 (no test users) needs no transform — the source carries only the two
#    service accounts. assert-realm.sh enforces that it stays that way.
#
# H4  Declare aggregator_id, decision_made, aggregator_type and
#     signalstack_org_id admin-only in the user profile
#     (attributes."kc.user.profile.config", a JSON string). Only service
#     accounts write them, through the admin API, and they feed token claims the
#     apps act on. Forced here rather than trusted from the source, so a source
#     realm without these declarations cannot drop them; any earlier
#     declaration of those names is replaced. unmanagedAttributePolicy is left
#     as the source has it. apply-user-profile.sh applies the same declarations
#     to realms that already exist.

jq '
  def is_local: test("localhost|127\\.0\\.0\\.1");

  def admin_only_names: ["aggregator_id", "decision_made", "aggregator_type", "signalstack_org_id"];
  def admin_only_attrs: [
    { name: "aggregator_id", displayName: "Aggregator id", permissions: { view: ["admin"], edit: ["admin"] }, multivalued: false },
    { name: "decision_made", displayName: "Registration decision", permissions: { view: ["admin"], edit: ["admin"] }, multivalued: false },
    { name: "aggregator_type", displayName: "Aggregator type", permissions: { view: ["admin"], edit: ["admin"] }, multivalued: false },
    { name: "signalstack_org_id", displayName: "Signals organisation id", permissions: { view: ["admin"], edit: ["admin"] }, multivalued: false }
  ];

  # JSON array form (redirectUris, webOrigins)
  def strip_local:
    if . == null then . else map(select(is_local | not)) end;

  # Keycloak "##"-delimited string form (post.logout.redirect.uris)
  def strip_local_hashlist:
    if . == null then .
    else (split("##") | map(select(is_local | not)) | join("##"))
    end;

  .sslRequired = "external"
  | .clients = [
      .clients[]
      | .redirectUris = (.redirectUris | strip_local)
      | .webOrigins   = (.webOrigins   | strip_local)
      | if (.attributes."post.logout.redirect.uris") then
          .attributes."post.logout.redirect.uris" |=  strip_local_hashlist
        else . end
    ]
  | .attributes."kc.user.profile.config" |= (
      (if . == null then error("source realm has no attributes.kc.user.profile.config") else fromjson end)
      | .attributes = ([(.attributes // [])[] | select(.name as $n | admin_only_names | index($n) | not)] + admin_only_attrs)
      | tojson
    )
' "$SRC" > "${OUT}.tmp"

mv "${OUT}.tmp" "$OUT"

echo "[build-realm] done. Transform summary:"
echo "  sslRequired : $(jq -r '.sslRequired' "$OUT")  (was $(jq -r '.sslRequired' "$SRC"))"
echo "  clients     : $(jq -r '.clients | length' "$OUT")"
echo "  realm roles : $(jq -r '[.roles.realm[]?.name] | join(", ")' "$OUT")"
echo "  users       : $(jq -r '[.users[]?.username] | join(", ")' "$OUT")"
echo "  admin-only  : $(jq -r '.attributes."kc.user.profile.config" | fromjson | [.attributes[] | select(.permissions.edit == ["admin"]) | .name] | join(", ")' "$OUT")"
removed=$(( $(jq '[.clients[] | (.redirectUris // []) + (.webOrigins // []) | length] | add' "$SRC") \
          - $(jq '[.clients[] | (.redirectUris // []) + (.webOrigins // []) | length] | add' "$OUT") ))
echo "  stripped    : ${removed} localhost redirect/origin entries"
echo
echo "Now run: scripts/assert-realm.sh $OUT"
