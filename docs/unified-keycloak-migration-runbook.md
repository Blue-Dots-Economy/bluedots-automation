# Runbook: migrating a running environment to the unified Keycloak

**Applies to:** any already-deployed environment that runs Keycloak inside the
`aggregator` release, upgrading to the shared `keycloak` release.

**Design reference:** `docs/superpowers/plans/2026-08-04-keycloak-common-service.md`
— that plan's §11 covers the reasoning; this runbook is the executable form of its
§11.3. Section numbers below refer to *this* document unless the plan is named.

**Read this first:** the realm is **recreated**, not renamed in place. Existing
Keycloak users are exported and re-imported with their ids preserved. This is safe
here because these realms are **OTP-only** — no password credentials exist, so
there is nothing an export/import round-trip can lose. The plan's credential-count
pre-flight is therefore **not required** and has been dropped from this runbook.

**User impact:** every session and SSO cookie is invalidated. All coordinators must
log in again. Plan a maintenance window.

---

## 1. Which path applies to you

| Situation | Path | What it involves |
|---|---|---|
| **New environment** — no Keycloak deployed, no existing users | **§5. Clean deployment** | Deploy in order. No migration, no maintenance window, no user export. ~30 min. |
| **Existing environment** — Keycloak running in the `aggregator` release with real coordinator users | **§6. Existing-environment upgrade** | Realm is recreated and users re-imported with ids preserved. Needs a maintenance window; all coordinators re-login. |

Sections 3 and 4 (preconditions, values) apply to **both**. Sections 7–11
(verification, rollback, closing out, the signals flip, gotchas) are written for
the upgrade path; §5 says which of them a clean deployment still needs.

If you are unsure which you are, check for an existing realm:

```bash
kubectl -n common-services exec deploy/<postgres-deploy> -- \
  psql -U postgres -d keycloak -c "select name from realm;"
```

A `keycloak` database that does not exist, or a realm list with only `master`,
means new environment. Anything with an `aggregator` (or already-renamed) realm
carrying users means the upgrade path.

---

## 2. What changes

| | Before | After |
|---|---|---|
| Keycloak owner | `aggregator` release, `aggregator` namespace | `keycloak` release, `common-services` namespace |
| Realm name | `aggregator` | `global.keycloakRealm` (per-instance, e.g. `bluedots`) |
| Realm contents | 2 clients, no realm roles | 7 clients (both DPGs), 3 realm roles, both service accounts, portal gate |
| Serves | aggregator only | aggregator **and** signals |
| Public URL | `https://<host>/auth` | **unchanged** |
| `keycloak` database | same shared Postgres | **same shared Postgres — not moved** |

The database does not move. Only the workload relocates and the realm inside it is
rebuilt. There is no cross-server user migration.

## 3. Preconditions

- The `unified-keycloak` changes are deployed from this branch (commit `82fc202`
  or later).
- `kubectl` context points at the target cluster. **Confirm it before every step:**
  `kubectl config current-context`.
- The Keycloak image tag in `<env>/global-images.yaml` was built **after** the
  `signals` login theme landed. The shared realm points `signals-ui` at a
  `signals` theme; an older image renders signals logins with the aggregator
  brand. Verify before starting, not after.
- `jq` and `curl` available locally.
- The three new client secrets exist in the generated `global-secrets.yaml`
  (`signalsApiSecret`, `signalstackClientSecret`, `voiceDpgSignalsSecret`) plus
  `keycloakPostgresPassword`. If the file predates this change, regenerate it:

  ```bash
  cd opentofu/aws/<env>
  bash install.sh apply_tf_output_file
  grep -E "signalsApiSecret|signalstackClientSecret|voiceDpgSignalsSecret|keycloakPostgresPassword" global-secrets.yaml
  ```

  All four must be non-empty. The Keycloak chart **fails the render** on any empty
  one rather than importing an empty client secret — that is deliberate.

## 4. Environment values to set

Edit `opentofu/aws/<env>/global-values.yaml` before deploying.

| Value | Set to | Why |
|---|---|---|
| `global.keycloakRealm` | the target realm name (e.g. `bluedots`) | Consumed by three charts — keycloak, aggregator, signals. They must agree or tokens validate against the wrong issuer. No chart has a literal default; a missing value fails the render. |
| `global.keycloak.realm` | same value | The signals chart's copy. |
| `global.keycloak.publicBaseUrl` | `https://<aggregator-host>/auth` | The **Keycloak** host, not a signals host — the issuer string in a token is built from it. |
| `keycloak.postgres.username` | **`aggregator`** | **Existing environments only.** The `keycloak` database is already owned by the `aggregator` role, and the bootstrap Job's `CREATE DATABASE` guard is a no-op, so the owner does not change. Leaving the default `keycloak` gives Keycloak a role with no access to its own database. |
| `global.publicHosts` | the signals hostnames | Builds signals-ui's redirect / origin / post-logout allow-lists. Wrong or empty here fails signals login with `invalid_redirect_uri` — and it looks fine locally. |
| `api.config.AUTH_PROVIDER` | leave at **`betterauth`** | Do **not** flip signals in this window. See §10. |

Static check before touching the cluster:

```bash
cd opentofu/aws/<env>
bash install.sh lint        # realm assertions + helm lint all five charts
```

### 4.1 Object names you will need

Confirmed against a `helm template` render of this branch, so these are the actual
names — not guesses.

| Thing | Name | Namespace |
|---|---|---|
| Old Keycloak Deployment / Service | `aggregator-keycloak` | `aggregator` |
| New Keycloak Deployment / Service | `keycloak-keycloak` | `common-services` |
| New Keycloak Secret | `keycloak-secrets` | `common-services` |
| Realm-reconciliation Job | `keycloak-init` | `common-services` |
| Realm ConfigMap (placeholders intact) | `keycloak-keycloak-realm` | `common-services` |
| Aggregator app Deployments | `aggregator-api`, `aggregator-web`, `aggregator-worker` | `aggregator` |
| Aggregator Secret / global ConfigMap | `aggregator-secrets` / `aggregator-global` | `aggregator` |
| Keycloak initContainers | `themes-init`, `realm-renderer` | — |

## 5. Clean deployment — new environment

No Keycloak exists, so there is nothing to migrate: the realm is created from the
chart's `realm.json` by `--import-realm` on first boot, which is the one case where
the deployed realm ends up byte-equivalent to the file this repo owns. No window
and no user export.

### 5.1 Set the values

Per §4, with one difference: leave `keycloak.postgres.username` at its default
**`keycloak`**. The `aggregator` override in §4 is for existing clusters only —
here the bootstrap Job creates both the role and the database with the right owner.

Also set `global.keycloakRealm` (and `global.keycloak.realm`) to the
per-instance realm name before the first deploy. Changing it later is the §6
migration, not a config tweak.

### 5.2 Deploy in order

```bash
cd opentofu/aws/<env>
bash install.sh lint                 # realm assertions + helm lint all five charts
bash install.sh deploy_all_services  # monitoring → common-services → keycloak → signals → aggregator
```

`deploy_all_services` already runs them in the required order. If deploying
piecemeal, the order is **mandatory**:

```bash
bash install.sh deploy_monitoring
bash install.sh deploy_common_services   # creates the `keycloak` role + database
bash install.sh deploy_keycloak          # imports the shared realm
bash install.sh deploy_signals
bash install.sh deploy_aggregator
bash install.sh fix_acme_issuer_uri
```

`keycloak` **must** follow `common-services`: its database is created by a
post-install hook of that release. And it must precede `signals`, whose api
asserts Keycloak config at boot once `AUTH_PROVIDER=keycloak`.

### 5.3 The one manual step between signals and aggregator

Unchanged by this work, and easy to miss on a new environment:
`global.signalstack.actingOrgId` only exists after the signals migrate-job seeds
the `organization` table. After `deploy_signals`, run `./get-signalstack-org-id.sh`,
set the value, then `deploy_aggregator`. Skip it and aggregator login fails with
`SIGNALSTACK_ORG_NOT_REGISTERED`.

### 5.4 Confirm the import ran

```bash
kubectl -n common-services logs -l app.kubernetes.io/name=keycloak --tail=200 | grep -i import
kubectl -n common-services logs deploy/keycloak-keycloak -c realm-renderer
kubectl -n common-services logs job/keycloak-init
```

Expect the realm to be **imported** (not skipped), the renderer to print
`rendered realm.json` plus the signals-ui origins it applied, and the init Job to
finish both scripts. A running pod already proves the renderer substituted every
placeholder — it fails the pod otherwise.

**No manual protocol-mapper step is needed.** The aggregator repo's `SETUP.md`
says two mappers must be added by hand after a fresh import; that does not apply
here. The shared realm declares all six on `aggregator-portal`
(`aggregator_id`, `decision_made`, `aggregator_type`, `phone_number`,
`signalstack_org_id`, `aggregator-api-audience`) and the init Job reconciles them
idempotently.

### 5.5 Verify

From §7, run: **realm contents match the chart**, **issuer**, **login theme**,
**end-to-end login**, **negative path**, **login rate limit**, and **service
paths**. Skip *users preserved* and *no stale sessions* — there is no prior state
to compare against.

Then create your first coordinator through the normal registration + approval
flow and confirm `/profile` renders.

§8 (rollback) and §9 (closing out) do not apply: there is no legacy realm and no
old Keycloak Deployment. §10 (the signals `AUTH_PROVIDER` flip) applies exactly as
written — a new environment with no signals users can flip immediately, since the
provisioning prerequisite is trivially satisfied.

---

## 6. Existing-environment upgrade

Everything from here to §6.12 applies **only** to an environment that already runs
Keycloak in the `aggregator` release. For a new environment, stop and use §5.

§6.1–6.6 are preparation and can be done ahead of time. §6.7–6.12 are the
maintenance window itself.

### 6.1 Shell access to Keycloak

Every step below uses an admin token. Keep this shell open for the whole window.

```bash
# Port-forward the CURRENT (aggregator-release) Keycloak.
kubectl -n aggregator port-forward svc/aggregator-keycloak 8080:8080 &
KC=http://localhost:8080/auth

# Bootstrap admin password from the aggregator release's Secret.
ADMIN_PW=$(kubectl -n aggregator get secret aggregator-secrets \
  -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)

tok() {
  curl -sS -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d username=admin -d "password=$ADMIN_PW" | jq -r .access_token
}
TOKEN=$(tok); [ -n "$TOKEN" ] && [ "$TOKEN" != null ] && echo "admin token OK"
```

Tokens expire in ~60s by default — re-run `TOKEN=$(tok)` whenever a call returns
401.

> If `sslRequired` is already `external` on a realm you are calling, a
> port-forward comes from a non-private source address and gets
> `403 "HTTPS required"`. The old `aggregator` realm is `none`, so this only
> applies to the new realm after §6.8 — use the in-cluster path from a debug pod, or
> temporarily set the realm's `sslRequired` to `none` for the call.

### 6.2 Back up

This is the rollback. Take both.

```bash
# Keycloak database
kubectl -n common-services exec deploy/<postgres-deploy> -- \
  pg_dump -U postgres keycloak > keycloak-pre-unify-$(date +%F).sql

# Aggregator database (holds the sub references — see 5.2)
kubectl -n common-services exec deploy/<postgres-deploy> -- \
  pg_dump -U postgres aggregator > aggregator-pre-unify-$(date +%F).sql
```

Confirm both files are non-empty and contain a `COPY`/`INSERT` for
`user_entity` and `aggregators` respectively before continuing.

### 6.3 Record the baseline

Keep this output — §7 compares against it.

**`realm.id` is a UUID, not the realm name.** Any query written as
`where realm_id = 'aggregator'` returns zero rows and passes vacuously. Always
resolve the realm by **name**:

```sql
-- user count
select count(*) from user_entity
  where realm_id = (select id from realm where name = 'aggregator');

-- the three attributes that gate the portal
select ua.name, count(*) from user_attribute ua
  join user_entity u on u.id = ua.user_id
  where u.realm_id = (select id from realm where name = 'aggregator')
    and ua.name in ('aggregator_id','decision_made','signalstack_org_id')
  group by ua.name;

-- decision_made distribution (approved vs pending)
select ua.value, count(*) from user_attribute ua
  join user_entity u on u.id = ua.user_id
  where u.realm_id = (select id from realm where name = 'aggregator')
    and ua.name = 'decision_made'
  group by ua.value;
```

And on the aggregator database:

```sql
select status, count(*) from aggregators group by status;
select count(*) from aggregator_orgs where owner_kc_sub is not null;
```

### 6.4 Confirm the realm is OTP-only

The whole export/import approach rests on this. Confirm rather than assume:

```sql
select c.type, count(*) from credential c
  join user_entity u on u.id = c.user_id
  where u.realm_id = (select id from realm where name = 'aggregator')
  group by c.type;
```

**Expected: zero rows.** If any `password` rows come back, stop — those users
would lose their credential on re-import, and you need the plan's §11.2.1 Path B
(rename in place + a client-creation reconciler) instead of this runbook.

### 6.5 Export the users

Captures ids, attributes, required actions **and realm-role mappings** — the last
one matters because org owners hold `org_owner` and role mappings are *not*
included in a plain user fetch.

```bash
OLD=aggregator
mkdir -p kc-export && cd kc-export

# Page through all users (default page size is 100).
: > users-raw.json
first=0
while :; do
  TOKEN=$(tok)
  page=$(curl -sS "$KC/admin/realms/$OLD/users?first=$first&max=100&briefRepresentation=false" \
    -H "Authorization: Bearer $TOKEN")
  n=$(echo "$page" | jq 'length')
  [ "$n" -eq 0 ] && break
  echo "$page" | jq -c '.[]' >> users-raw.json
  first=$((first + n))
  echo "exported $first users so far"
done
wc -l users-raw.json

# Attach each user's realm-role mappings.
: > users-with-roles.json
while read -r u; do
  id=$(echo "$u" | jq -r .id)
  TOKEN=$(tok)
  roles=$(curl -sS "$KC/admin/realms/$OLD/users/$id/role-mappings/realm" \
    -H "Authorization: Bearer $TOKEN" | jq '[.[].name]')
  echo "$u" | jq --argjson r "$roles" '. + {realmRoles: $r}' >> users-with-roles.json
done < users-raw.json

# Build the partialImport payload, keeping only fields Keycloak accepts and that
# we actually need. `id` is what preserves the sub.
jq -s '{
  ifResourceExists: "SKIP",
  users: [ .[] | {
    id, username, email, firstName, lastName,
    enabled, emailVerified, createdTimestamp,
    attributes, requiredActions, realmRoles
  } ]
}' users-with-roles.json > partial-import.json

echo "users to import: $(jq '.users | length' partial-import.json)"
jq -r '.users[0] | "sample: \(.username) id=\(.id)"' partial-import.json
```

**Check before continuing:** `users to import` must equal the §6.3 user count, and
the file must contain `aggregator_id` values:

```bash
test "$(jq '.users | length' partial-import.json)" = "<count from 5.2>" && echo "count matches"
jq '[.users[] | select(.attributes.aggregator_id != null)] | length' partial-import.json
```

### 6.6 Dry-run the import against a copy

Do not trust `partialImport` untested on a live realm. Restore the §6.2 dump into a
scratch database, point a throwaway Keycloak at it, and run §6.9 there first.
Confirm ids and `aggregator_id` survive. Skip this only if you have already
validated the round-trip on this Keycloak version in another environment.

---

> **The window starts here.** §6.7 onwards takes logins down. Everything above is
> safe to run in advance.

Order matters. Do not reorder steps 6.2 and 6.4.

### 6.7 Stop the aggregator apps

Leave the old Keycloak running — step 6.2 needs it.

```bash
kubectl -n aggregator scale deploy/aggregator-api deploy/aggregator-web deploy/aggregator-worker --replicas=0
kubectl -n aggregator get deploy
```

### 6.8 Rename the existing realm out of the way

This frees the target realm name so the new release's `--import-realm` creates it
fresh and complete, and leaves the old realm intact beside it as an instant
rollback.

`PUT /admin/realms/{realm}` with a changed `.realm` field renames in place and
preserves every user id. Verified against Keycloak 26.5.5 (the pinned version): it
returns 204, the old name 404s, the new name serves OIDC discovery, and Keycloak
also renames the `<realm>-realm` admin client in `master`. It is undocumented
upstream and the admin console does not expose it.

```bash
OLD=aggregator
LEGACY=aggregator-legacy
TOKEN=$(tok)

curl -fsS "$KC/admin/realms/$OLD" -H "Authorization: Bearer $TOKEN" \
  | jq --arg new "$LEGACY" '.realm = $new' > /tmp/realm-legacy.json

curl -fsS -X PUT "$KC/admin/realms/$OLD" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @/tmp/realm-legacy.json

# Verify: old name must 404, legacy name must answer.
curl -s -o /dev/null -w 'old  %{http_code}\n' "$KC/realms/$OLD/.well-known/openid-configuration"
curl -s -o /dev/null -w 'new  %{http_code}\n' "$KC/realms/$LEGACY/.well-known/openid-configuration"
```

Expect `old 404` and `new 200`. If the rename did not take, stop — do not proceed
to 6.4, or you will import into a realm name that is still in use.

**Flow-id collision check.** Two realms coexist from here, and the shared realm's
portal-gate flow carries a pinned id that must be unique per Keycloak server:

```bash
TOKEN=$(tok)
curl -fsS "$KC/admin/realms/$LEGACY/authentication/flows" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.[] | select(.id == "9f3b1c52-7a41-4c8e-9d16-3b0f5a2e7c84") | "COLLISION: \(.alias)"'
```

No output means no collision — expected, since the legacy realm predates that
flow. Any output means stop and raise it; the import in 6.3 would fail.

### 6.9 Scale the old Keycloak down, then deploy the new release

Scale down rather than delete: it is the cheapest rollback target.

```bash
kubectl -n aggregator scale deploy/aggregator-keycloak --replicas=0

cd opentofu/aws/<env>
bash install.sh deploy_keycloak
```

Watch the boot and confirm the realm import **RAN** (this is Path A — the opposite
of an in-place upgrade, where you would expect it to be skipped):

```bash
kubectl -n common-services logs -l app.kubernetes.io/name=keycloak --tail=200 | grep -i "import"
```

You want a line reporting the realm being imported. If it says the import was
skipped, the target realm already existed — stop and investigate before importing
users.

Also confirm the realm-renderer initContainer substituted everything:

```bash
kubectl -n common-services logs deploy/keycloak-keycloak -c realm-renderer
```

It prints `rendered realm.json -> ...` and the signals-ui origins it applied. It
**fails the pod** if any `__PLACEHOLDER__` survived, so a running pod means the
substitution was complete.

### 6.10 Re-import the users

Re-point the port-forward at the new Keycloak, then import.

```bash
kill %1 2>/dev/null   # drop the old port-forward
kubectl -n common-services port-forward svc/keycloak-keycloak 8080:8080 &
KC=http://localhost:8080/auth

ADMIN_PW=$(kubectl -n common-services get secret keycloak-secrets \
  -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)
TOKEN=$(tok)

NEW=<global.keycloakRealm>     # e.g. bluedots

curl -sS -o /tmp/import-result.json -w 'HTTP %{http_code}\n' \
  -X POST "$KC/admin/realms/$NEW/partialImport" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @kc-export/partial-import.json

jq '{added, skipped, overwritten}' /tmp/import-result.json
```

Expect HTTP 200 and `added` equal to the §6.3 user count. `POST /users` would
ignore the supplied ids — `partialImport` honours them, which is why it is used
here. Preserving the `sub` is non-negotiable: it is referenced by
`aggregator_orgs.owner_kc_sub`, `bulk_uploads.uploaded_by`,
`registration_links.created_by` and `aggregators.created_by`/`updated_by`.

### 6.11 Flush the aggregator session store

Sessions hold tokens minted under the old issuer and will not re-validate. Leaving
them means users hit an opaque failure instead of a clean re-login.

```bash
kubectl -n aggregator exec deploy/<aggregator-redis-or-common-redis> -- \
  sh -c "redis-cli --scan --pattern 'session:*' | xargs -r redis-cli del"
```

If Redis requires auth, prefix with `redis-cli -a "$REDIS_PASSWORD"`.

### 6.12 Bring the apps back

```bash
cd opentofu/aws/<env>
bash install.sh deploy_signals      # AUTH_PROVIDER still betterauth — wiring lands inert
bash install.sh deploy_aggregator
bash install.sh fix_acme_issuer_uri
```

`deploy_aggregator` scales the apps back up as part of the upgrade. Confirm all
three are running before verifying.

---

## 7. Verification

Run all of these before declaring the window closed.

**Users preserved.** Re-run every §6.3 query against the **new** realm name. Each
count must match its pre-migration value exactly:

```sql
select count(*) from user_entity
  where realm_id = (select id from realm where name = '<new realm>');
```

A lower count means the import was partial. A count of zero with a healthy pod is
the silent-lockout case — the realm exists but is empty. Roll back (§8).

**Realm contents match the chart.** This is the check that catches what the init
Job tolerates silently (`ensure_acting_org_mapper` logs
`client '<id>' not found — skipping` and returns 0):

```bash
TOKEN=$(tok)
echo "clients:"; curl -fsS "$KC/admin/realms/$NEW/clients" -H "Authorization: Bearer $TOKEN" \
  | jq -r '[.[].clientId] | map(select(test("aggregator|signals|voice"))) | sort | join(", ")'
echo "realm roles:"; curl -fsS "$KC/admin/realms/$NEW/roles" -H "Authorization: Bearer $TOKEN" \
  | jq -r '[.[].name] | map(select(test("org_owner|signals_"))) | sort | join(", ")'
```

Expect all 7 clients (`aggregator-api`, `aggregator-bff`, `aggregator-dpg`,
`aggregator-portal`, `signals-api`, `signals-ui`, `voice-dpg`) and all 3 roles
(`org_owner`, `signals_participant`, `signals_admin`).

**Issuer.** `GET /realms/<new>/.well-known/openid-configuration` returns 200 and
its `issuer` matches what the apps derive:

```bash
kubectl -n aggregator get cm aggregator-global -o jsonpath='{.data.OIDC_ISSUER}'; echo
```

**Login theme.** Open the aggregator login page and a signals login page. They must
render *different* brands. Both showing the aggregator brand means the Keycloak
image predates the `signals` theme (§3).

**End-to-end login.** One real approved coordinator completes OTP login, lands on
the portal, and `/profile` renders. A `403 MISSING_AGGREGATOR_ID` means the
`aggregator_id` attribute or its protocol mapper did not survive — check the
keycloak-init Job logs.

**Negative path.** A `decision_made=pending` account is refused at the gate with
the entitlement message, not an OTP prompt. This confirms `apply-portal-gate.py`
applied — it has never run in any environment before this release.

**Login rate limit actually matches.** It used to fail *open* silently whenever the
realm was not literally named `aggregator`:

```bash
for i in $(seq 1 25); do
  curl -s -o /dev/null -w '%{http_code} ' \
    -X POST "https://<host>/auth/realms/$NEW/login-actions/authenticate"
done; echo
```

Expect `429`s once past the configured per-minute limit.

**Service paths.** `/health/ready` is 200 on the aggregator api; the worker picks
up a job; one bulk upload runs to completion (exercises the `aggregator-api`
service account).

**No stale sessions.** `redis-cli --scan --pattern 'session:*'` returns only
sessions created after the window.

---

## 8. Rollback

The legacy realm and the old Keycloak Deployment are both intact until §9, so
rollback is fast. Re-login is **not** undoable, so roll back on failed
verification — not on cosmetic issues.

### 8.1 Fast path — the new realm is wrong or empty

Nothing was destroyed; the old realm is sitting beside it under
`aggregator-legacy`.

```bash
# 1. Scale the new Keycloak down.
kubectl -n common-services scale deploy/keycloak-keycloak --replicas=0

# 2. Rename the legacy realm back to the name the apps expect.
TOKEN=$(tok)   # against the OLD keycloak (scale it up first, see step 3)
curl -fsS "$KC/admin/realms/aggregator-legacy" -H "Authorization: Bearer $TOKEN" \
  | jq '.realm = "aggregator"' > /tmp/realm-restore.json
curl -fsS -X PUT "$KC/admin/realms/aggregator-legacy" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @/tmp/realm-restore.json

# 3. Bring the old Keycloak back.
kubectl -n aggregator scale deploy/aggregator-keycloak --replicas=1
```

Then revert `global.keycloakRealm` (and `global.keycloak.*`) to `aggregator` in
`global-values.yaml`, flush sessions again (§6.11), and
`bash install.sh deploy_aggregator`.

Order note: step 2 needs a running Keycloak to serve the admin API. Scale the old
one up first, then rename, then confirm.

### 8.2 The import was partial

Do **not** re-run `partialImport` with `ifResourceExists: "SKIP"` expecting it to
fill gaps — it will skip the ids that already exist and you cannot tell repaired
from stale. Delete the new realm and redo §6.9–6.10 cleanly:

```bash
TOKEN=$(tok)
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$KC/admin/realms/$NEW" \
  -H "Authorization: Bearer $TOKEN"
```

Deleting the new realm does not touch `aggregator-legacy`. Then re-run
`deploy_keycloak` (the import recreates the realm) and re-import.

### 8.3 Last resort

Stop the stack, restore the `keycloak` database from the §6.2 dump, revert
`global-values.yaml`, redeploy. Anything written to Keycloak after the backup —
new registrations, approvals — is lost; reconcile against `aggregators` rows
created during the window.

---

## 9. Closing out

Only after both DPGs are verified and you are past your rollback window:

```bash
# Remove the legacy realm.
TOKEN=$(tok)
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$KC/admin/realms/aggregator-legacy" \
  -H "Authorization: Bearer $TOKEN"

# Remove the old Keycloak Deployment (it is no longer in the aggregator chart, so
# `helm upgrade` leaves the orphaned object behind — delete it explicitly).
kubectl -n aggregator delete deploy/aggregator-keycloak
kubectl -n aggregator delete svc/aggregator-keycloak
kubectl -n aggregator delete ingress -l app.kubernetes.io/component=keycloak
```

Record in the environment's deployment branch: the date, the realm name, and that
`keycloak.postgres.username` is pinned to `aggregator` (§4) so the next operator
does not "fix" it to the default.

---

## 10. Deferred: flipping signals to Keycloak

**This is a separate window. Do not bundle it with the migration above.**

`AUTH_PROVIDER` accepts only `betterauth` or `keycloak` — `dual` was removed
upstream, so there is no mode that accepts both. The cutover is a **hard flip**,
and every existing signals user must already exist in the shared realm before it.

Prerequisite, owned by signals-dpg and **not** satisfied by this runbook: provision
every existing signals user into the realm. There is no just-in-time backfill
during cutover.

When that is done:

```bash
# In <env>/global-values.yaml
#   api.config.AUTH_PROVIDER: keycloak
cd opentofu/aws/<env>
bash install.sh deploy_signals
```

Verify:
- A signals participant completes OIDC login and lands in the UI.
- An `aggregator-portal` token is **rejected** on signals' human session path.
  This is what `KEYCLOAK_ACCEPTED_CLIENT_IDS: signals-ui` enforces; the realm is
  shared, so without it an aggregator token would be honoured by signals.
- The signals login page renders the **signals** brand, not the aggregator one.

Rollback is setting `AUTH_PROVIDER` back to `betterauth` and redeploying —
provided no user has been created Keycloak-only since the flip.

---

## 11. Notes carried from the design

Four things that are easy to get wrong and cost a window each:

1. **`realm.id` is a UUID, not the realm name.** Baseline queries keyed on
   `realm_id = 'aggregator'` return zero rows and "pass" — including in the
   catastrophic empty-realm case. Always resolve by `name`.
2. **A healthy Keycloak pod does not mean a populated realm.** Realm import applies
   only to an empty realm, so a wrong realm name yields a new empty realm and a
   green pod. Every login fails while nothing looks broken.
3. **The init Job reconciles but does not create clients.**
   `ensure_acting_org_mapper` logs `client '<id>' not found — skipping` and returns
   0, so a missing signals client is silently tolerated and the Job still succeeds.
   That is why §7 asserts the *running* realm's contents, not just the chart file.
4. **`sslRequired` is `external` on the new realm.** In-cluster callers (private
   source addresses) are exempt, so the init Job works over plain HTTP. A
   `kubectl port-forward` is *not* exempt and gets `403 "HTTPS required"` — expected,
   not a fault.
