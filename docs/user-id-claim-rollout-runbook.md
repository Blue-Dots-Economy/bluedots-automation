# Runbook: moving an existing environment from `aggregator_id` to `user_id`

**Applies to:** an environment that is already running, with live coordinators,
moving to the release that replaces the `aggregator_id` token claim and
Keycloak attribute with `user_id` (aggregator-dpg #1082, #1083, #1084, #1085
and #1188, issue #852). All five ship in **one release**, deployed in a
**maintenance window**.

**Not needed for:** a brand-new environment. Its realm is imported from
`realm.json`, which already uses `user_id` only, and it has no coordinators to
backfill. Deploy it the usual way (`docs/deployment_guide.md` in
bluedots-automation).

**Paths** are relative to a checkout of the **bluedots-automation** repository,
unless another repository is named.

## 1. What this changes

Every coordinator's id moves from `aggregator_id` to `user_id`, in Keycloak and
in their sign-in token. After the release:

- **Keycloak** maps only `user_id` into the tokens of `aggregator-portal` and
  `campaign-manager`. The portal's sign-in gate checks `user_id`. The
  `aggregator_id` mappers are removed.
- **The aggregator** reads only `user_id`, and writes only `user_id` for new
  coordinators. Bulk upload jobs carry the id as `userId` only.
- **The aggregator's API responses** for the coordinator profile, invite accept
  and onboarding totals return the id as `user_id`, and the portal reads it
  there. The API and the portal must be on the same release.
- **Signals** recognises an aggregator account by `user_id` only. Wording only.
- **Existing coordinators** get `user_id` from a one-off **backfill**, and their
  old `aggregator_id` is then removed by a one-off **cleanup**.

What does **not** change: no database migration. Org owners and the network
admin carry neither claim, before and after. Users see nothing once the window
ends, though some may have to sign in again.

**Until the backfill has run, existing coordinators cannot sign in.** That is
why this runs in a maintenance window, with users kept out until §9.

**After the cleanup (§11) there is no quick rollback.** Rolling back after that
point needs the Keycloak database snapshot from §10.

## 2. Before you start

You need:

- **The release.** Image tags in `opentofu/aws/<env>/global-images.yaml` that
  contain all of the aggregator-dpg and signals-dpg changes above, and a
  checkout of bluedots-automation that contains the matching Keycloak change.
- **Access.** `kubectl` and `helm` against the cluster, with rights in the
  `common-services`, `aggregator` and `signals` namespaces.
- **Somewhere to run from.** The environment directory: `cd opentofu/aws/<env>/`,
  on that environment's deployment branch. `bash install.sh preflight` must pass.
- **Keycloak admin access** for the checks in §9 and §12: the admin console, or
  shell access to the Keycloak pod.
- **A maintenance window** of about 30 minutes plus the backfill and cleanup
  time (§8 shows how to estimate it).

The commands below use the default namespaces and release names. If your
environment overrides them (`CS_NS`, `AGG_NS`, `CS_REL`, … in `install.sh`), use
your values. Objects are found by label, so generated names never need guessing.

| Thing | Default | How to find yours |
| --- | --- | --- |
| Keycloak namespace | `common-services` | `kubectl get deploy -A \| grep keycloak` |
| Keycloak deployment | `keycloak-keycloak` | same command |
| Aggregator namespace | `aggregator` | `kubectl get ns` |
| Redis pod | `common-services-redis-master-0` | `kubectl -n common-services get pods \| grep redis` |
| Realm name | the value of `global.keycloakRealm` | `opentofu/aws/<env>/global-values.yaml` |

> Write every `EXTRA_HELM_ARGS` below exactly as shown: **no quotes inside the
> value**. `install.sh` splits it on spaces without removing quotes, so a quoted
> value reaches Helm with the quotes and the Job is not configured.

> **Why some steps end with a re-check.** Each backfill and cleanup write
> replaces the whole Keycloak user, and takes no lock. Every
> `deploy_aggregator` restarts the API pods, and each starting pod rewrites
> every user's `roles`. So once in a while one of the two writes is lost. A
> lost write shows up in the next dry run as work left to do, and running the
> step again fixes it. Do not change roles during the window.

## 3. Back up the Keycloak database

Follow §6.2 of `docs/unified-keycloak-migration-runbook.md` (in-cluster Postgres
or RDS). Back up the `keycloak` database, and verify the dump as that section
describes. Store it outside the repository. This is the rollback point for
§4–§10.

## 4. Start the window

1. **Close the portal to users** with your usual maintenance notice. Org owners,
   the network admin and coordinators must not sign in until §9 passes.
2. **Let running bulk uploads finish.** After the release, a bulk job queued by
   the old release cannot be read. Wait until all three bulk queues are empty.
   Each of these prints `0`:

   ```bash
   kubectl -n common-services exec common-services-redis-master-0 -- sh -c '
     for q in bulk-file-process bulk-row-process bulk-finalise; do
       for s in wait active delayed prioritized; do
         t=$(redis-cli -a "$REDIS_PASSWORD" --no-auth-warning type "bull:$q:$s")
         case "$t" in
           list) redis-cli -a "$REDIS_PASSWORD" --no-auth-warning llen "bull:$q:$s" ;;
           zset) redis-cli -a "$REDIS_PASSWORD" --no-auth-warning zcard "bull:$q:$s" ;;
           *)    echo 0 ;;
         esac
       done
     done'
   ```

   If your Redis has no password, drop `-a "$REDIS_PASSWORD" --no-auth-warning`.

## 5. Deploy Keycloak

```bash
bash install.sh deploy_keycloak
```

The deploy ends with the Keycloak init Job, a Helm hook. It is **deleted as
soon as it succeeds**, so read its log **while it runs**, from a second
terminal:

```bash
kubectl -n common-services get jobs -w                 # note the name ending in -init
kubectl -n common-services logs -f job/<name-ending-in-init>
```

Expect these lines (on a later run, "already present — skip" or "no
aggregator_id mapper — skip" instead):

```
[kc-init] N user(s) still store aggregator_id — keeping its admin-only declaration until instance-upgrade remove-aggregator-id has run
[kc-init] unmanagedAttributePolicy=ENABLED phoneNumber declared=1 admin-only identity attributes=5/5
[kc-init] aggregator-portal: user_id mapper created
[kc-init] campaign-manager: user_id mapper created
[kc-init] aggregator-portal: aggregator_id mapper removed
[kc-init] campaign-manager: aggregator_id mapper removed
```

The portal gate script then rebuilds the gate on `user_id`. If the Job fails,
`deploy_keycloak` fails too. Do not continue: read the Job's log, fix the
cause, and run this step again. A failed lookup, create or delete prints
`FAILED` with the Keycloak response, and a gate failure prints
`GATE NOT APPLIED`.

## 6. Deploy the aggregator

```bash
bash install.sh deploy_aggregator
```

Existing coordinators cannot sign in yet: their tokens have no `user_id`. Keep
users out.

## 7. Deploy Signals

```bash
bash install.sh deploy_signals
```

## 8. Backfill: copy `aggregator_id` into `user_id`

The backfill runs as the aggregator's instance-upgrade Job. It is switched on
for one deploy at a time through `EXTRA_HELM_ARGS`. A Job's arguments cannot be
changed in place, so **delete the previous Job before each run**:

```bash
kubectl -n aggregator delete job -l app.kubernetes.io/component=instance-upgrade --ignore-not-found
```

### 8a. Dry run

Reads only. It also checks that the database is fully upgraded.

```bash
EXTRA_HELM_ARGS="--set aggregator-api.instanceUpgrade.enabled=true --set aggregator-api.instanceUpgrade.args={backfill-user-id,--dry-run}" \
  bash install.sh deploy_aggregator
kubectl -n aggregator logs -f -l app.kubernetes.io/component=instance-upgrade
```

Expect one line:

```
backfill-user-id {"candidates":N,"copied":N,"already":0,"notInKeycloak":0,"conflicts":0,"failed":0} (dry run)
```

On a dry run, `copied` means "would copy".

| You see | Meaning | Do |
| --- | --- | --- |
| `REFUSED: … runs after the instance upgrade` | The database is not fully upgraded. | Stop. Finish the instance upgrade first (aggregator-dpg `docs/user-org-migration-runbook.md`). |
| `conflicts` > 0, with `user_id differs: coordinator <id>` lines | Those coordinators have a `user_id` that differs from their `aggregator_id`. Nothing writes such a value, so someone set it by hand. | In the Keycloak admin console, set each listed coordinator's `user_id` equal to its `aggregator_id`, then repeat 8a. |
| `notInKeycloak` > 0 | Coordinators with no Keycloak user. | Nothing; they cannot sign in anyway. |
| `failed` > 0 | Keycloak did not answer. | Repeat 8a. |
| `conflicts` 0, `failed` 0 | Ready. | Continue. |

Time for the real run: **N ÷ 5 seconds** at the default rate; the cleanup in
§11 takes about the same. To go faster, if Keycloak has room, add a rate:
`{backfill-user-id,--rate,10}`.

### 8b. Real run

Delete the Job, then:

```bash
EXTRA_HELM_ARGS="--set aggregator-api.instanceUpgrade.enabled=true --set aggregator-api.instanceUpgrade.args={backfill-user-id}" \
  bash install.sh deploy_aggregator
kubectl -n aggregator logs -f -l app.kubernetes.io/component=instance-upgrade
```

Expect `conflicts` and `failed` both 0, and the Job to complete
(`kubectl -n aggregator get job -l app.kubernetes.io/component=instance-upgrade`
shows `COMPLETIONS 1/1`). If `failed` is above 0, run 8b again: it skips the
coordinators already done.

### 8c. Re-check until clean

Repeat 8a. Expect `"copied":0` and `"already":N`. If `copied` is above 0, a
write was lost (see §2): run 8b again, then repeat this check until `copied`
is 0.

## 9. Smoke test, users still out

1. **A coordinator signs in** to the portal and the dashboard loads.
2. **An org owner and the network admin** sign in and land on the console.
3. **A coordinator's token carries `user_id` and no `aggregator_id`.**

   *Admin console:* open the realm, then **Clients → `aggregator-portal` →
   Client scopes → Evaluate**. Pick a coordinator under **Users** and open
   **Generated access token**. It shows `user_id`, and no `aggregator_id`.

   *Shell:* run Keycloak's admin CLI inside the Keycloak pod. Inside the pod,
   `localhost` is a private address, so the realm's HTTPS rule does not refuse
   it. Replace `<realm>` and `<coordinator-username>`:

   ```bash
   kubectl -n common-services exec deploy/keycloak-keycloak -- sh -c '
     K=/opt/keycloak/bin/kcadm.sh; C=/tmp/kcadm.cfg
     $K config credentials --config $C --server http://localhost:8080/auth --realm master \
        --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
     CID=$($K get clients -r "$1" --config $C -q clientId=aggregator-portal --fields id --format csv --noquotes)
     U=$($K get users -r "$1" --config $C -q username="$2" -q exact=true --fields id --format csv --noquotes)
     $K get clients/$CID/evaluate-scopes/generate-example-access-token -r "$1" --config $C -q userId=$U -q scope=openid
   ' sh <realm> <coordinator-username> | grep -E '"(aggregator_id|user_id)"'
   ```

   It prints only the `user_id` line.

4. **A bulk upload** of a small file completes.
5. **The coordinator's Account Details and Onboarding pages** load. They read
   the renamed `user_id` field, so this confirms the API and the portal were
   updated together.

If any of these fails, stop here and roll back (§13, "before the cleanup").

## 10. Snapshot the Keycloak database again

Take a second backup as in §3. It is the only way back once §11 has run.

## 11. Cleanup: remove `aggregator_id`

This removes each coordinator's `aggregator_id` from Keycloak. It refuses any
coordinator whose `user_id` is missing or different, so it cannot run ahead of
the backfill. **It is the point of no return** for a quick rollback.

Delete the Job before each run, as in §8.

### 11a. Dry run

```bash
EXTRA_HELM_ARGS="--set aggregator-api.instanceUpgrade.enabled=true --set aggregator-api.instanceUpgrade.args={remove-aggregator-id,--dry-run}" \
  bash install.sh deploy_aggregator
kubectl -n aggregator logs -f -l app.kubernetes.io/component=instance-upgrade
```

Expect:

```
remove-aggregator-id {"candidates":N,"removed":N,"absent":0,"notBackfilled":0,"failed":0} (dry run)
```

| You see | Meaning | Do |
| --- | --- | --- |
| `notBackfilled` > 0, with `user_id missing or different: coordinator <id>` lines | The backfill has not reached them. | Go back to §8c. |
| `failed` > 0 | Keycloak did not answer. | Repeat 11a. |
| `notBackfilled` 0, `failed` 0 | Ready. | Continue. |

### 11b. Real run

```bash
EXTRA_HELM_ARGS="--set aggregator-api.instanceUpgrade.enabled=true --set aggregator-api.instanceUpgrade.args={remove-aggregator-id}" \
  bash install.sh deploy_aggregator
kubectl -n aggregator logs -f -l app.kubernetes.io/component=instance-upgrade
```

### 11c. Re-check until clean

Repeat 11a. Expect `"removed":0` and `"absent":N`. If `removed` is above 0,
run 11b again, then repeat this check.

### 11d. Remove the Job

```bash
kubectl -n aggregator delete job -l app.kubernetes.io/component=instance-upgrade
bash install.sh deploy_aggregator
```

## 12. Drop the `aggregator_id` declaration

```bash
bash install.sh deploy_keycloak
```

Read the init Job's log as in §5. Expect:

```
[kc-init] no user stores aggregator_id — dropping its declaration
```

If it says `N user(s) still store aggregator_id`, a Keycloak user that is not
a coordinator in the aggregator database still carries the attribute. Find
those users in the admin console (**Users → search by attribute**,
`aggregator_id`), remove the attribute by hand, and run this step again.

Repeat the sign-in and token checks from §9. Then **end the window**.

## 13. Rollback

**Before the cleanup (§11)**, no data has been lost: `aggregator_id` is still
stored on every coordinator.

1. Roll back the aggregator and Keycloak:
   `helm -n aggregator history aggregator`, then
   `helm -n aggregator rollback aggregator <revision>`; the same for
   `keycloak` in `common-services`. Signals is independent:
   `helm -n signals rollback signals <revision>`.
2. **Add the `aggregator_id` mapper back to `aggregator-portal` by hand.** The
   older init Job does not create it, and the new one removed it. In the admin
   console: **Clients → `aggregator-portal` → Client scopes →
   `aggregator-portal-dedicated` → Add mapper → By configuration → User
   Attribute**, with name, user attribute and token claim name all
   `aggregator_id`, added to the access token only, single-valued.
3. The older portal gate script rebuilds the gate on `aggregator_id` on its
   next run. Check the init Job log for its success line.

**After the cleanup (§11)**, coordinators no longer store `aggregator_id`, so
the older release cannot identify them. Restore the Keycloak database from the
§10 snapshot, then do steps 1 and 3 above. Anything changed in Keycloak since
the snapshot is lost. Prefer fixing forward on the new release.
