# Runbook: deploying the unified Keycloak

**Applies to:** standing up a new environment, or moving an existing one from the
aggregator-owned Keycloak to the shared `keycloak` release.

**Design reference:** `docs/superpowers/plans/2026-08-04-keycloak-common-service.md`.
Section numbers below refer to *this* document unless the plan is named.

**The realm is not renamed and users are not migrated.** An existing environment
keeps the realm it already has; the realm's *contents* are reconciled in place by
the `keycloak-init` Job. Because the realm name is unchanged the issuer URL is
unchanged, and Keycloak 26.5.5 runs with `PERSISTENT_USER_SESSIONS` enabled (its
sessions live in the database, not pod memory) — so **there is no forced re-login
and no user-visible outage beyond the brief Keycloak restart.**

---

## 1. Which path applies to you

| Situation | Path | Involves |
|---|---|---|
| **New environment** — no Keycloak deployed, no users | **§5** | Deploy in order. ~30 min. |
| **Existing environment** — Keycloak in the `aggregator` release with real coordinators | **§6** | Move the workload, reconcile the realm in place. No rename, no export, no re-login. |

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
| Realm name | `aggregator` | **unchanged** |
| Issuer URL | `https://<host>/auth/realms/<realm>` | **unchanged** |
| Realm contents | 2 clients, no realm roles | 7 clients (both DPGs), 3 realm roles, both service accounts, portal gate |
| Serves | aggregator only | aggregator **and** signals |
| `keycloak` database | shared Postgres | **same database, untouched** |
| Users / sessions | — | **preserved** |

Only the workload relocates. The database is not touched and the realm is not
recreated — the init Job adds what is missing.

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
| `global.keycloakRealm` | existing env: **the realm name you already have** (e.g. `aggregator`). New env: the per-instance name you want. | Consumed by three charts — keycloak, aggregator, signals. They must agree or tokens validate against the wrong issuer. No chart has a literal default. Pointing it at a name that does *not* exist creates a new empty realm — see §11. |
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

The realm stays where it is and keeps its name. The `keycloak-init` Job reconciles
its contents — adding the 5 missing clients, the 2 missing realm roles and the
service-account role grants — so there is no rename, no user export and no
re-import.

### 6.1 Back up

Cheap insurance even though nothing here rewrites user data.

```bash
kubectl -n common-services exec deploy/<postgres-deploy> -- \
  pg_dump -U postgres keycloak > keycloak-pre-unify-$(date +%F).sql
```

Confirm the file is non-empty and contains `user_entity` before continuing.

### 6.2 Record the baseline

Two counts, so §7 can prove nothing was lost.

**`realm.id` is a UUID, not the realm name.** A query written as
`where realm_id = 'aggregator'` returns zero rows and "passes" vacuously — including
in the empty-realm failure case. Always resolve by **name**:

```sql
select count(*) from user_entity
  where realm_id = (select id from realm where name = '<realm>');

select ua.name, count(*) from user_attribute ua
  join user_entity u on u.id = ua.user_id
  where u.realm_id = (select id from realm where name = '<realm>')
    and ua.name in ('aggregator_id','decision_made','signalstack_org_id')
  group by ua.name;
```

Also note the current client list, so you can see what the Job adds:

```sql
select c.client_id from client c
  join realm r on r.id = c.realm_id where r.name = '<realm>' order by 1;
```

### 6.3 Set the values

Per §4, taking the **existing environment** column. The two that matter most:

- `global.keycloakRealm` = the name from §6.2. **Do not change it.** A different
  name creates a second, empty realm and every login fails while the pod looks
  healthy (§11).
- `keycloak.postgres.username` = `aggregator`.

### 6.4 Scale the old Keycloak down

Scale rather than delete — it is the rollback target, and two Keycloaks against
one database serving the same realm is not worth risking.

```bash
kubectl -n aggregator scale deploy/aggregator-keycloak --replicas=0
```

The aggregator apps can stay up; they will fail auth calls for the minute or two
until §6.5 completes. Scale them down too if you prefer a clean error page:

```bash
kubectl -n aggregator scale deploy/aggregator-api deploy/aggregator-web --replicas=0
```

### 6.5 Deploy the shared Keycloak

```bash
cd opentofu/aws/<env>
bash install.sh deploy_keycloak
```

Then read the init Job log — this is where the reconcile happens:

```bash
kubectl -n common-services logs job/keycloak-init
```

Expected on the first run against an existing realm:

```
[kc-init] 1/4 render realm
[kc-init] 2/4 apply-realm-config.py (clients + roles + SA grants)
[realm-config] partialImport: added=8 skipped=2
[realm-config]   added REALM_ROLE signals_participant
[realm-config]   added REALM_ROLE signals_admin
[realm-config]   added CLIENT signals-ui
[realm-config]   added CLIENT signals-api
[realm-config]   added CLIENT aggregator-bff
[realm-config]   added CLIENT aggregator-dpg
[realm-config]   added CLIENT voice-dpg
[realm-config]   service-account-signals-api: granted realm-management [...]
[kc-init] 3/4 apply-user-profile.sh
[kc-init] 4/4 apply-portal-gate.py
[kc-init] realm reconciliation complete
```

Counts vary with what the environment already had. What matters:

- **`skipped` is non-zero.** Existing clients are skipped, never overwritten —
  re-creating one would change its service-account user id, and those ids are
  referenced from the aggregator database.
- **`added` covers the clients your §6.2 list was missing.**
- **The Job exits 0 having run all four steps.** It fails the deploy otherwise.

Confirm the realm import was **skipped** — it applies only to an empty realm, so
on an existing one it must not run:

```bash
kubectl -n common-services logs deploy/keycloak-keycloak | grep -i "import"
```

A line reporting an *imported* realm here means the configured realm name did not
match an existing realm and Keycloak created a fresh empty one. Stop and go to §8.

### 6.6 Bring the apps back

```bash
bash install.sh deploy_signals      # AUTH_PROVIDER still betterauth — wiring lands inert
bash install.sh deploy_aggregator
bash install.sh fix_acme_issuer_uri
```

Sessions are **not** flushed: the issuer is unchanged and Keycloak persists its
sessions, so existing logins stay valid. If you do hit stale-session symptoms,
clearing them is safe and forces a clean re-login:

```bash
kubectl -n aggregator exec deploy/<redis> -- \
  sh -c "redis-cli --scan --pattern 'session:*' | xargs -r redis-cli del"
```

---

## 7. Verification

**Users preserved.** Re-run the §6.2 counts. They must match exactly. A count of
zero against a healthy pod is the empty-realm case — go to §8.

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

**Issuer unchanged.** Must equal its pre-migration value:

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

The old Keycloak is scaled down, not deleted, and the realm was never rewritten —
so rollback is a scale-up.

```bash
kubectl -n common-services scale deploy/keycloak-keycloak --replicas=0
kubectl -n aggregator      scale deploy/aggregator-keycloak --replicas=1
kubectl -n aggregator      scale deploy/aggregator-api deploy/aggregator-web --replicas=1
```

The clients and roles the Job added are additive and harmless to the old setup —
the aggregator ignores clients it does not use — so there is nothing to undo in
the realm.

**If an empty realm was created** (the configured name did not match): do not try
to merge it. Delete the empty realm, correct `global.keycloakRealm` to the real
name, and re-run §6.5. The original realm was never touched.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X DELETE "$KC/admin/realms/<wrong-name>" \
  -H "Authorization: Bearer $TOKEN"
```

**Last resort.** Restore the `keycloak` database from the §6.1 dump, revert
`global-values.yaml`, redeploy. Anything written to Keycloak after the backup —
new registrations, approvals — is lost; reconcile against `aggregators` rows
created during the window.

---

## 9. Closing out

Once verified and past your rollback window, remove the old Keycloak. It is no
longer in the aggregator chart, so `helm upgrade` leaves the orphaned objects
behind and they must be deleted explicitly:

```bash
kubectl -n aggregator delete deploy/aggregator-keycloak
kubectl -n aggregator delete svc/aggregator-keycloak
kubectl -n aggregator delete ingress -l app.kubernetes.io/component=keycloak
```

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

1. **A healthy Keycloak pod does not mean a populated realm.** Realm import applies
   only to an empty realm, so a `global.keycloakRealm` that does not match an
   existing realm yields a brand-new empty one and a green pod. Every login fails
   while nothing looks broken. This is the single most dangerous misconfiguration
   here — §6.2 and §6.5 exist to catch it.
2. **`realm.id` is a UUID, not the realm name.** Baseline queries keyed on
   `realm_id = '<name>'` return zero rows and "pass", including in case 1.
3. **The older init scripts reconcile but never create clients.**
   `ensure_acting_org_mapper` and `ensure_login_theme` log
   `client '<id>' not found — skipping` and return 0. `apply-realm-config.py` runs
   before them precisely so they find the clients; if that step is ever removed or
   reordered, missing clients become a silent no-op again.
4. **`sslRequired` is `external` on a freshly imported realm.** In-cluster callers
   (private source addresses) are exempt, so the init Job works over plain HTTP. A
   `kubectl port-forward` is *not* exempt and gets `403 "HTTPS required"` —
   expected, not a fault. Existing realms keep whatever they had.
