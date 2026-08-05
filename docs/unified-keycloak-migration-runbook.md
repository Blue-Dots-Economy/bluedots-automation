# Runbook: deploying the unified Keycloak

**Applies to:** standing up a new environment, or moving an existing one from the
aggregator-owned Keycloak to the shared `keycloak` release.

**Design reference:** `docs/superpowers/plans/2026-08-04-keycloak-common-service.md`.
Section numbers below refer to *this* document unless the plan is named.

**An existing environment moves to the new unified realm.** The new realm is
created fresh from the chart's `realm.json`, and existing Keycloak users are
exported and re-imported into it with their ids (`sub`) preserved. The old realm is
left untouched beside it as the rollback.

**No realm is renamed.** The unified realm name differs from the existing one, so
the fresh import simply creates it alongside — there is nothing to rename out of
the way. Verified: the previously-deployed realm pins no authentication-flow ids,
so the new realm's pinned entitlement-gate flow cannot collide with it.

**User impact:** the realm name changes, so the issuer URL changes and every
session and SSO cookie is invalidated. All coordinators log in again. Plan a
maintenance window. Users are OTP-only, so nothing is lost in the round-trip —
there are no password credentials to carry.

---

## 1. Which path applies to you

| Situation | Path | Involves |
|---|---|---|
| **New environment** — no Keycloak deployed, no users | **§5** | Deploy in order. ~30 min. |
| **Existing environment** — Keycloak in the `aggregator` release with real coordinators | **§6** | Deploy the shared Keycloak, migrate users into the new unified realm. Maintenance window; coordinators re-login. |

§3 and §4 apply to both. If unsure which you are:

```bash
kubectl -n common-services exec deploy/<postgres-deploy> -- \
  psql -U postgres -d keycloak -c "select name from realm;"
```

No `keycloak` database, or only `master`, means new environment. Any realm
carrying users means §6.

## 2. What changes

| | Before | After |
|---|---|---|
| Keycloak owner | `aggregator` release, `aggregator` namespace | `keycloak` release, `common-services` namespace |
| Realm | `aggregator` (2 clients, no realm roles) | new unified realm, created fresh: 7 clients (both DPGs), 3 realm roles, both service accounts, portal gate |
| Issuer URL | `.../realms/aggregator` | `.../realms/<new realm>` — **changes** |
| Serves | aggregator only | aggregator **and** signals |
| `keycloak` database | shared Postgres | **same database** — both realms live in it |
| Users | in the old realm | **copied** into the new realm, `sub` preserved |
| Sessions | — | invalidated; coordinators re-login |

The database is not moved and the old realm is not modified. The new realm is
created next to it and users are copied across.

## 3. Preconditions

- The `unified-keycloak` changes are deployed from this branch.
- `kubectl` context points at the target cluster. **Confirm before every step:**
  `kubectl config current-context`.
- The Keycloak image tag in `<env>/global-images.yaml` was built **after** the
  `signals` login theme landed. The shared realm points `signals-ui` at a
  `signals` theme; an older image renders signals logins with the aggregator
  brand. Verify before starting, not after.
- Four new secrets exist in the generated `global-secrets.yaml`:

  ```bash
  cd opentofu/aws/<env>
  bash install.sh apply_tf_output_file
  grep -E "signalsApiSecret|signalstackClientSecret|voiceDpgSignalsSecret|keycloakPostgresPassword" global-secrets.yaml
  ```

  All four must be non-empty. The chart **fails the render** on any empty one
  rather than installing an empty client secret — deliberate.

## 4. Environment values to set

Edit `opentofu/aws/<env>/global-values.yaml`.

| Value | Set to | Why |
|---|---|---|
| `global.keycloakRealm` | the **new unified** realm name (e.g. `bluedots`), for both new and existing environments | Consumed by three charts — keycloak, aggregator, signals. They must agree or tokens validate against the wrong issuer. No chart has a literal default. On an existing environment this deliberately names a realm that does not exist yet, so `--import-realm` creates it complete; §6 then copies users in. Getting it wrong in the *other* direction — naming a realm that exists but is empty — is the dangerous case (§11). |
| `global.keycloak.realm` | same value | The signals chart's copy. |
| `global.keycloak.publicBaseUrl` | `https://<aggregator-host>/auth` | The **Keycloak** host, not a signals host — the issuer string in a token is built from it. |
| `keycloak.postgres.username` | existing: **`aggregator`** · new: leave `keycloak` | An existing `keycloak` database is already owned by the `aggregator` role and the bootstrap Job's `CREATE DATABASE` guard is a no-op, so the owner does not change. Leaving the default on an existing cluster gives Keycloak a role with no access to its own database. |
| `global.publicHosts` | the signals hostnames | Builds signals-ui's redirect / origin / post-logout allow-lists. Wrong or empty fails signals login with `invalid_redirect_uri` — and it looks fine locally, where everything is localhost. |
| `api.config.AUTH_PROVIDER` | leave at **`betterauth`** | Do not flip signals in this window. §10. |

Static check before touching the cluster:

```bash
cd opentofu/aws/<env>
bash install.sh lint        # realm assertions + helm lint all five charts
```

### 4.1 Object names

Confirmed against a `helm template` render of this branch.

| Thing | Name | Namespace |
|---|---|---|
| Old Keycloak Deployment / Service | `aggregator-keycloak` | `aggregator` |
| New Keycloak Deployment / Service | `keycloak-keycloak` | `common-services` |
| New Keycloak Secret | `keycloak-secrets` | `common-services` |
| Realm-reconciliation Job | `keycloak-init` | `common-services` |
| Aggregator app Deployments | `aggregator-api`, `aggregator-web`, `aggregator-worker` | `aggregator` |
| Aggregator Secret / global ConfigMap | `aggregator-secrets` / `aggregator-global` | `aggregator` |
| Keycloak initContainers | `themes-init`, `realm-renderer` | — |

---

## 5. Clean deployment — new environment

Nothing to migrate: `--import-realm` creates the realm from the chart's
`realm.json` on first boot, which is the one case where the deployed realm is
byte-equivalent to the file this repo owns.

### 5.1 Set the values

Per §4, taking the **new environment** column: leave
`keycloak.postgres.username` at `keycloak` (the bootstrap Job creates both role
and database), and choose `global.keycloakRealm` before the first deploy.

### 5.2 Deploy in order

```bash
cd opentofu/aws/<env>
bash install.sh lint
bash install.sh deploy_all_services   # monitoring → common-services → keycloak → signals → aggregator
```

Deploying piecemeal, the order is **mandatory**:

```bash
bash install.sh deploy_monitoring
bash install.sh deploy_common_services   # creates the `keycloak` role + database
bash install.sh deploy_keycloak          # imports the shared realm
bash install.sh deploy_signals
bash install.sh deploy_aggregator
bash install.sh fix_acme_issuer_uri
```

`keycloak` **must** follow `common-services` — its database is created by a
post-install hook of that release — and precede `signals`, whose api asserts
Keycloak config at boot once `AUTH_PROVIDER=keycloak`.

### 5.3 The manual step between signals and aggregator

Unchanged by this work and easy to miss on a first install.
`global.signalstack.actingOrgId` only exists after the signals migrate-job seeds
the `organization` table. After `deploy_signals`, run
`./get-signalstack-org-id.sh`, set the value, then `deploy_aggregator`. Skip it
and aggregator login fails with `SIGNALSTACK_ORG_NOT_REGISTERED`.

### 5.4 Confirm

```bash
kubectl -n common-services logs -l app.kubernetes.io/name=keycloak --tail=200 | grep -i import
kubectl -n common-services logs deploy/keycloak-keycloak -c realm-renderer
kubectl -n common-services logs job/keycloak-init
```

Expect the realm **imported**, the renderer printing `rendered realm.json` plus
the signals-ui origins it applied, and the init Job completing all four steps. A
running pod already proves every placeholder was substituted — the renderer fails
the pod otherwise.

**No manual protocol-mapper step.** The aggregator repo's `SETUP.md` says two
mappers must be added by hand after a fresh import; that does not apply here. The
shared realm declares all six on `aggregator-portal` (`aggregator_id`,
`decision_made`, `aggregator_type`, `phone_number`, `signalstack_org_id`,
`aggregator-api-audience`) and the init Job reconciles them idempotently.

### 5.5 Verify

From §7 run everything except *users preserved* — there is no prior state to
compare. Then create your first coordinator through the normal registration +
approval flow and confirm `/profile` renders.

§8 and §9 do not apply (no old Keycloak, no legacy state). §10 applies as written,
and a new environment can flip immediately since it has no signals users to
provision.

---

## 6. Existing-environment upgrade

The new unified realm is created fresh; existing users are copied into it with
their ids preserved. The old realm is never modified — it stays as the rollback.

§6.1–6.4 are preparation and safe to run in advance. §6.5 onwards is the window.

### 6.1 Shell access to Keycloak

Keep this shell for the whole procedure.

```bash
kubectl -n aggregator port-forward svc/aggregator-keycloak 8080:8080 &
KC=http://localhost:8080/auth
OLD=aggregator                    # the existing realm
NEW=<global.keycloakRealm>        # the new unified realm, e.g. bluedots

ADMIN_PW=$(kubectl -n aggregator get secret aggregator-secrets \
  -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)

tok() {
  curl -sS -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli \
    -d username=admin -d "password=$ADMIN_PW" | jq -r .access_token
}
TOKEN=$(tok); [ -n "$TOKEN" ] && [ "$TOKEN" != null ] && echo "admin token OK"
```

Tokens expire in ~60s — re-run `TOKEN=$(tok)` on any 401.

### 6.2 Back up

This is the rollback for anything that goes wrong at the database level.

```bash
kubectl -n common-services exec deploy/<postgres-deploy> -- \
  pg_dump -U postgres keycloak > keycloak-pre-unify-$(date +%F).sql
```

Confirm the file is non-empty and mentions `user_entity` before continuing.

### 6.3 Record the baseline

§7 compares against this. **`realm.id` is a UUID, not the realm name** — a query
keyed on `realm_id = 'aggregator'` returns zero rows and "passes" vacuously.
Resolve by **name**:

```sql
select count(*) from user_entity
  where realm_id = (select id from realm where name = 'aggregator');

select ua.name, count(*) from user_attribute ua
  join user_entity u on u.id = ua.user_id
  where u.realm_id = (select id from realm where name = 'aggregator')
    and ua.name in ('aggregator_id','decision_made','signalstack_org_id')
  group by ua.name;

select ua.value, count(*) from user_attribute ua
  join user_entity u on u.id = ua.user_id
  where u.realm_id = (select id from realm where name = 'aggregator')
    and ua.name = 'decision_made'
  group by ua.value;
```

Confirm the realm is OTP-only — the whole copy approach rests on it:

```sql
select c.type, count(*) from credential c
  join user_entity u on u.id = c.user_id
  where u.realm_id = (select id from realm where name = 'aggregator')
  group by c.type;
```

**Expected: zero rows.** Any `password` rows mean those credentials would be lost
in the copy — stop and raise it.

### 6.4 Export the users

Captures ids, attributes, required actions **and realm-role mappings**. That last
one matters: role mappings are not included in a plain user fetch, so org owners
would silently lose `org_owner`.

```bash
mkdir -p kc-export && cd kc-export

# Page through all users (default page size is 100).
: > users-raw.json
first=0
while :; do
  TOKEN=$(tok)
  page=$(curl -sS "$KC/admin/realms/$OLD/users?first=$first&max=100&briefRepresentation=false" \
    -H "Authorization: Bearer $TOKEN")
  n=$(echo "$page" | jq 'length'); [ "$n" -eq 0 ] && break
  echo "$page" | jq -c '.[]' >> users-raw.json
  first=$((first + n)); echo "exported $first so far"
done

# Attach each user's realm-role mappings.
: > users-with-roles.json
while read -r u; do
  id=$(echo "$u" | jq -r .id); TOKEN=$(tok)
  roles=$(curl -sS "$KC/admin/realms/$OLD/users/$id/role-mappings/realm" \
    -H "Authorization: Bearer $TOKEN" | jq '[.[].name]')
  echo "$u" | jq --argjson r "$roles" '. + {realmRoles: $r}' >> users-with-roles.json
done < users-raw.json

# Build the partialImport payload. `id` is what preserves the sub.
jq -s '{
  ifResourceExists: "SKIP",
  users: [ .[] | {
    id, username, email, firstName, lastName,
    enabled, emailVerified, createdTimestamp,
    attributes, requiredActions, realmRoles
  } ]
}' users-with-roles.json > partial-import.json

echo "users to import: $(jq '.users | length' partial-import.json)"
jq '[.users[] | select(.attributes.aggregator_id != null)] | length' partial-import.json
cd ..
```

`users to import` must equal the §6.3 count, and the `aggregator_id` count must be
non-zero.

**Dry-run it once against a copy.** Restore the §6.2 dump into a scratch database,
point a throwaway Keycloak at it, and run §6.7 there. Confirm ids and
`aggregator_id` survive. `partialImport` is untested on this Keycloak version in
this environment; do not trust it live first.

> **The window starts here.** §6.5 onwards takes logins down.

### 6.5 Stop the aggregator apps and the old Keycloak

The old Keycloak is scaled down, not deleted — it is the fast rollback. Its realm
data stays in the database either way.

```bash
kubectl -n aggregator scale deploy/aggregator-api deploy/aggregator-web deploy/aggregator-worker --replicas=0
kubectl -n aggregator scale deploy/aggregator-keycloak --replicas=0
```

### 6.6 Deploy the shared Keycloak

`global.keycloakRealm` names a realm that does not exist yet, so `--import-realm`
creates it complete — all 7 clients, 3 realm roles, both service accounts and the
entitlement-gate flow.

```bash
cd opentofu/aws/<env>
bash install.sh deploy_keycloak
```

Confirm the import **ran** (on a brand-new realm it must):

```bash
kubectl -n common-services logs deploy/keycloak-keycloak | grep -i import
kubectl -n common-services logs deploy/keycloak-keycloak -c realm-renderer
kubectl -n common-services logs job/keycloak-init
```

The renderer prints `rendered realm.json` plus the signals-ui origins it applied,
and fails the pod if any placeholder survived — a running pod proves substitution
completed. The init Job runs four steps; `apply-realm-config.py` is a no-op here
because the fresh import already created everything, and that is expected:

```
[realm-config] partialImport: added=0 skipped=10
```

It exists as the safety net for a realm that has *drifted* from `realm.json` —
which is what used to fail silently, since the older scripts log
`client '<id>' not found — skipping` and return 0 rather than creating anything.

If the import was **skipped**, the realm already existed. Stop: you are about to
import users into the wrong realm, possibly an empty one (§11).

### 6.7 Copy the users in

Re-point the port-forward at the new Keycloak.

```bash
kill %1 2>/dev/null
kubectl -n common-services port-forward svc/keycloak-keycloak 8080:8080 &
KC=http://localhost:8080/auth
ADMIN_PW=$(kubectl -n common-services get secret keycloak-secrets \
  -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)
TOKEN=$(tok)

curl -sS -o /tmp/import-result.json -w 'HTTP %{http_code}\n' \
  -X POST "$KC/admin/realms/$NEW/partialImport" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @kc-export/partial-import.json

jq '{added, skipped, overwritten}' /tmp/import-result.json
```

Expect HTTP 200 and `added` equal to the §6.3 user count. `POST /users` would
ignore the supplied ids; `partialImport` honours them. Preserving the `sub` is
non-negotiable — it is referenced by `aggregator_orgs.owner_kc_sub`,
`bulk_uploads.uploaded_by`, `registration_links.created_by` and
`aggregators.created_by`/`updated_by`.

### 6.8 Flush the aggregator session store

The issuer changed, so existing sessions hold tokens that will not re-validate.
Clearing them turns an opaque failure into a clean re-login.

```bash
kubectl -n aggregator exec deploy/<redis> -- \
  sh -c "redis-cli --scan --pattern 'session:*' | xargs -r redis-cli del"
```

### 6.9 Bring the apps back

```bash
cd opentofu/aws/<env>
bash install.sh deploy_signals      # AUTH_PROVIDER still betterauth — wiring lands inert
bash install.sh deploy_aggregator
bash install.sh fix_acme_issuer_uri
```

---

## 7. Verification

**Users copied.** Run the §6.3 counts again, but against the **new** realm name.
Each must match the value recorded from the old realm:

```sql
select count(*) from user_entity
  where realm_id = (select id from realm where name = '<new realm>');
```

A lower count means the import was partial; zero against a healthy pod means the
users went somewhere else (or the realm is empty). Either way, §8.

**Realm contents.** This is the check that catches what the older scripts tolerated
silently:

```bash
kubectl -n common-services exec deploy/keycloak-keycloak -- true   # confirm pod is up
```

Then, from a shell with an admin token against the realm:

```bash
echo "clients:"; curl -fsS "$KC/admin/realms/$REALM/clients" -H "Authorization: Bearer $TOKEN" \
  | jq -r '[.[].clientId] | map(select(test("aggregator|signals|voice"))) | sort | join(", ")'
echo "roles:";   curl -fsS "$KC/admin/realms/$REALM/roles" -H "Authorization: Bearer $TOKEN" \
  | jq -r '[.[].name] | map(select(test("org_owner|signals_"))) | sort | join(", ")'
```

Expect all 7 clients (`aggregator-api`, `aggregator-bff`, `aggregator-dpg`,
`aggregator-portal`, `signals-api`, `signals-ui`, `voice-dpg`) and all 3 roles
(`org_owner`, `signals_participant`, `signals_admin`).

**Issuer.** Must now name the *new* realm, and match what the apps derive:

```bash
kubectl -n aggregator get cm aggregator-global -o jsonpath='{.data.OIDC_ISSUER}'; echo
```

**Login theme.** Open an aggregator login page and a signals login page — they must
render *different* brands. Both showing the aggregator brand means the Keycloak
image predates the `signals` theme (§3).

**End-to-end login.** A real approved coordinator completes OTP login, reaches the
portal, and `/profile` renders. `403 MISSING_AGGREGATOR_ID` means the
`aggregator_id` attribute or its mapper is missing — check the init Job log.

**Negative path.** A `decision_made=pending` account is refused at the gate with
the entitlement message, not an OTP prompt. This is the first time
`apply-portal-gate.py` has ever run in a deployed environment, so verify it
explicitly.

**Login rate limit.** It used to fail *open* silently whenever the realm was not
literally named `aggregator`:

```bash
for i in $(seq 1 25); do
  curl -s -o /dev/null -w '%{http_code} ' \
    -X POST "https://<host>/auth/realms/$REALM/login-actions/authenticate"
done; echo
```

Expect `429`s past the configured per-minute limit.

**Service paths.** `/health/ready` is 200 on the aggregator api; the worker picks
up a job; one bulk upload completes (exercises the `aggregator-api` service
account).

---

## 8. Rollback

**The old realm was never modified.** Rollback is reverting the realm name and
scaling the old Keycloak back up — the new realm can simply be abandoned or deleted.

```bash
# 1. Revert global.keycloakRealm (and global.keycloak.realm) to `aggregator`
#    in <env>/global-values.yaml.

# 2. Bring the old Keycloak back and take the new one down.
kubectl -n common-services scale deploy/keycloak-keycloak --replicas=0
kubectl -n aggregator      scale deploy/aggregator-keycloak --replicas=1

# 3. Flush sessions again (the issuer is reverting) and redeploy the apps.
cd opentofu/aws/<env>
bash install.sh deploy_aggregator
```

**If the user import was partial**, do not re-run it expecting the gaps to fill:
`ifResourceExists: SKIP` skips ids that already exist, so you cannot tell repaired
from stale. Delete the new realm and redo §6.6–6.7 cleanly. This is safe — the new
realm holds nothing but copies.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$KC/admin/realms/$NEW" \
  -H "Authorization: Bearer $TOKEN"
```

**Last resort.** Restore the `keycloak` database from the §6.2 dump, revert
`global-values.yaml`, redeploy. Anything written to Keycloak after the backup —
new registrations, approvals — is lost; reconcile against `aggregators` rows
created during the window.

---

## 9. Closing out

Once verified and past your rollback window:

```bash
# Remove the old realm (it still holds the original copies of every user).
TOKEN=$(tok)
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$KC/admin/realms/$OLD" \
  -H "Authorization: Bearer $TOKEN"

# Remove the old Keycloak. It is no longer in the aggregator chart, so
# `helm upgrade` leaves these orphaned — delete them explicitly.
kubectl -n aggregator delete deploy/aggregator-keycloak
kubectl -n aggregator delete svc/aggregator-keycloak
kubectl -n aggregator delete ingress -l app.kubernetes.io/component=keycloak
```

Deleting the old realm is irreversible except from the §6.2 dump. Leave it in place
until at least one full business cycle has passed with real logins.

Record in the environment's deployment branch: the realm name, and that
`keycloak.postgres.username` is pinned to `aggregator` (§4), so the next operator
does not "fix" it to the default.

---

## 10. Deferred: flipping signals to Keycloak

**A separate window. Do not bundle it with §6.**

`AUTH_PROVIDER` accepts only `betterauth` or `keycloak` — `dual` was removed
upstream, so there is no mode that accepts both. The cutover is a **hard flip**,
and every existing signals user must already exist in the shared realm.

Prerequisite, owned by signals-dpg and **not** satisfied by this runbook: provision
every existing signals user into the realm. There is no just-in-time backfill.

```bash
# <env>/global-values.yaml → api.config.AUTH_PROVIDER: keycloak
cd opentofu/aws/<env>
bash install.sh deploy_signals
```

Verify:
- A signals participant completes OIDC login and reaches the UI.
- An `aggregator-portal` token is **rejected** on signals' human session path.
  That is what `KEYCLOAK_ACCEPTED_CLIENT_IDS: signals-ui` enforces; the realm is
  shared, so without it an aggregator token would be honoured by signals.
- The signals login page renders the **signals** brand.

Rollback is setting `AUTH_PROVIDER` back to `betterauth` and redeploying, provided
no user has been created Keycloak-only since the flip.

---

## 11. Four things that cost a window each

1. **A healthy Keycloak pod does not mean a populated realm.** Import applies only
   to an empty realm. On this migration that is exactly what you want at §6.6 — but
   it also means a typo'd realm name gives you a green pod serving a realm with no
   users, and every login fails while nothing looks broken. The import-ran check in
   §6.6 and the count comparison in §7 exist to catch it.
2. **`realm.id` is a UUID, not the realm name.** Baseline queries keyed on
   `realm_id = '<name>'` return zero rows and "pass", including in case 1.
3. **The older init scripts reconcile but never create clients.**
   `ensure_acting_org_mapper` and `ensure_login_theme` log
   `client '<id>' not found — skipping` and return 0. `apply-realm-config.py` was
   added to close that gap and runs before them so they find the clients. It is a
   no-op on this migration (the fresh import already created everything) — its job
   is any realm that later drifts from `realm.json`. If that step is removed or
   reordered, missing clients become a silent no-op again.
4. **`sslRequired` is `external` on a freshly imported realm.** In-cluster callers
   (private source addresses) are exempt, so the init Job works over plain HTTP. A
   `kubectl port-forward` is *not* exempt and gets `403 "HTTPS required"` —
   expected, not a fault. Existing realms keep whatever they had.
