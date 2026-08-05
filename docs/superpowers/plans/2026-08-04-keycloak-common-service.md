# Plan: Keycloak as a common service (better-auth → Keycloak, both DPGs)

**Date:** 2026-08-04
**Branch:** `unified-keycloak`
**Repos touched by this plan:** `bluedots-automation` only (see §12 for what must already be true in the app repos)

## 1. Goal

Move Keycloak out of the `aggregator` release and into `common-services`, so a
single Keycloak instance with a single shared realm serves **both** DPGs. This is
the deployment half of the better-auth → Keycloak migration: signals-dpg has
already replaced better-auth with Keycloak in code, but nothing in this repo
deploys or configures Keycloak for signals.

## 2. The decision this plan assumes (already settled upstream)

**One shared realm per instance, holding both DPGs' clients.**

Evidence, not assumption:

- `signals-dpg/packages/config/src/secrets.ts:92` — `KEYCLOAK_REALM` defaults to
  `bluedots`, commented "One shared realm per instance, holding both DPGs'
  clients (§3.1)".
- `secrets.ts:109` — `KEYCLOAK_ACCEPTED_CLIENT_IDS` exists *because* the realm is
  shared: signals must reject tokens minted for clients it does not serve. Its
  config guard says so explicitly.
- `signals-dpg/docs/2026-07-29-keycloak-realm-topology-feedback.md` argued for
  one realm **per DPG**. That recommendation was **not adopted** — the code went
  shared. This plan follows the code.

Consequence for this repo: there is exactly one Keycloak Deployment, one realm,
one login-flow namespace, and one place that owns the realm definition.

A hard constraint follows from the merged realm JSON: one auth flow carries a
**pinned `id`**, and flow ids are unique per Keycloak server. **One Keycloak
cannot import that realm twice under two names.** Any "two realms on one server"
fallback is foreclosed — do not plan for it.

## 3. Scope

### 3.1 The two-track model (important — it frames everything below)

`infra/keycloak/` in **each** app repo is a deliberately **independent
developer-local setup**. Those trees are not upstream of this repo and are not
being consolidated. They exist so a developer can run either DPG standalone.

`bluedots-automation/helm/` is the **only** path to real environments. This repo
**owns** the deployment realm outright.

So the work is not "vendor from a canonical upstream" — it is: **take the latest
Keycloak setup from both app repos, merge it, harden it for production, and land
it here as this repo's own artefact.** Divergence between an app repo's local
realm and this repo's deployment realm is expected and correct, not drift.

**In scope**
- A `keycloak` chart at `helm/keycloak/` (its own release, deployed into the
  `common-services` namespace — see the §9 correction), owning the merged shared
  realm and init scripts as first-class files of this repo.
- A one-time merge of the latest Keycloak setup from **both** app repos, plus the
  production-hardening transform (§5.2).
- Removing the `keycloak` subchart from `helm/aggregator/` and repointing the
  aggregator apps at the common instance.
- Adding the Keycloak env/secret surface to `helm/signals/` (it has none today).
- `install.sh` deploy-order and function changes.
- Migrating the **currently deployed `aggregator` realm** into the new common
  realm, preserving all existing users (§11).
- Content assertions + a re-merge procedure, since this repo now owns the realm.

**Out of scope**
- Any change inside `signals-dpg` or `aggregator-dpg`, including their
  `infra/keycloak/` local-dev trees — they stay as they are.
- Phase C service auth (`x-api-key` → client-credentials bearer).

## 4. Current state

### 4.1 Where Keycloak lives now

| Fact | Location |
|---|---|
| Keycloak subchart | `helm/aggregator/charts/keycloak/` |
| Realm JSON (deployed) | `helm/aggregator/charts/keycloak/files/aggregator-realm.json` |
| Init script (deployed) | `helm/aggregator/files/apply-user-profile.sh` |
| Init Job | `helm/aggregator/templates/job-keycloak-init.yaml` (post-install/post-upgrade hook) |
| Realm name value | `global.keycloakRealm` → `KEYCLOAK_REALM`, `aggregator.publicBaseUrl`/`auth/realms/<realm>` |
| Keycloak DB | created by `common-services` bootstrap: `CREATE DATABASE keycloak OWNER aggregator` |
| Namespace / release | `aggregator` / `aggregator` |

### 4.2 Three defects to fix rather than carry forward

**D1 — the deployment realm lags what both apps now require.**
`helm/aggregator/charts/keycloak/files/aggregator-realm.json` against the current
local-dev setups it should have been kept in step with:

| | aggregator-dpg local | signals-dpg local | **deployed chart realm** |
|---|---|---|---|
| realm name | `__KEYCLOAK_REALM__` (templated) | `bluedots` (hardcoded) | **`aggregator`** |
| clients | **7** (both DPGs) | 4 (signals only) | **2** |
| realm roles | `org_owner`, `signals_participant`, `signals_admin` | 2 | **none** |
| service accounts | both | signals only | aggregator only |
| login themes | `otp` + per-client `signals-ui → signals` | none | — |
| auth flows | 9 (incl. portal gate) | 2 | 2 |
| extra users | — | — | **`testuser`, `alice`** (enabled) |

Two live consequences: org approval calls `assignRealmRole(..., 'org_owner')`
against a role that does not exist in what is deployed, and the chart ships test
user fixtures into real environments.

**D2 — the deployed init script is the oldest of the three.**

| Copy | Lines |
|---|---|
| `aggregator-dpg/infra/keycloak/init/apply-user-profile.sh` | 536 |
| `signals-dpg/infra/keycloak/init/apply-user-profile.sh` | 232 |
| `helm/aggregator/files/apply-user-profile.sh` (**deployed**) | 273 |

The two app-repo copies differing from each other is expected under §3.1 — they
configure two different local setups. The defect is only the third row: the
deployed copy differs from the richest app-repo version by 399 lines, so real
environments get roughly half the reconciliation logic. Separately,
`apply-portal-gate.py` (the `aggregator-portal` entitlement gate) is **not in this
repo at all**, so that gate has never been applied in any AWS environment.

**D3 — `helm/signals/` has no Keycloak wiring whatsoever.**
`grep -rli keycloak helm/signals/` returns nothing. Signals in AWS is still
entirely on better-auth; there is no env surface to point it at a realm.

### 4.3 Two smaller traps

- **Realm name hardcoded in the rate-limit path.**
  `helm/aggregator/charts/keycloak/values.yaml` sets `loginRateLimit.realm: aggregator`,
  and the template renders it into `/auth/realms/{{ $rl.realm }}/login-actions/authenticate`.
  It does **not** derive from `global.keycloakRealm`. Once the realm is `bluedots`,
  the per-IP OTP/login rate limit silently stops matching any route — it fails
  open with no error. Same class of bug as the `otp-ratelimit-ingress` realm path.
- **Keycloak DB owned by the `aggregator` role.** Ownership is coupled to the app
  being moved away from.

## 5. Target state

One Keycloak in `common-services`, owned by the platform chart, consumed
cross-namespace by both DPGs.

| Concern | Target |
|---|---|
| Chart | `helm/keycloak/` (chart `keycloak-platform`, thin umbrella over `charts/keycloak/`) |
| Namespace / release | `common-services` / **`keycloak`** — its own release; the one place release name ≠ directory-derived namespace |
| Realm definition | `helm/keycloak/charts/keycloak/files/realm.json` — **owned by this repo**, built by `scripts/build-realm.sh` (merge §5.1 + hardening §5.2), gated by `scripts/assert-realm.sh` |
| Realm name | `global.keycloakRealm`, single value, consumed by all three charts |
| Public URL | unchanged shape: `https://<host>/auth`, Kong ingress from `common-services` |
| In-cluster URL | `http://keycloak-keycloak.common-services.svc.cluster.local:8080/auth` |
| Keycloak DB | `keycloak` database, owner changed to a dedicated `keycloak` role |
| Themes + SPI | one image carrying `otp` **and** `signals` themes plus the OTP SPI |
| Init | one Job in the keycloak release running `apply-user-profile.sh` **then** `apply-portal-gate.py` |

### 5.1 The merge — and why it is already effectively done

Both app repos' local realms were compared field-by-field. **The aggregator repo's
local realm is a verified strict superset of the signals one**, so the merge is a
copy of the aggregator file plus a check that signals' contribution survived — not
a hand-reconciliation.

Evidence:

| Merge question | Result |
|---|---|
| Clients | aggregator local has all **7** (`aggregator-portal`, `aggregator-api`, `aggregator-bff`, `signals-ui`, `signals-api`, `aggregator-dpg`, `voice-dpg`); signals local has 4, all present in the 7 |
| The 4 shared clients, field-level | **Identical** across both files — `publicClient`, `serviceAccountsEnabled`, `directAccessGrantsEnabled`, `standardFlowEnabled`, `redirectUris`, and all protocol mappers (`phone_number`, `phone_number_verified`, `signals-api-audience`, `signals_acting_orgs`) |
| Only difference on a shared client | aggregator's copy **adds** `login_theme: signals` to `signals-ui` — an addition, not a divergence |
| Realm roles | aggregator local has all 3 (`org_owner`, `signals_participant`, `signals_admin`); signals has 2, both present |
| Service accounts | aggregator local has both; signals has one, present |
| OTP login flow | **Functionally identical.** `aggregator-otp-browser` and signals' `bluedots-otp-browser` have the same executions (`auth-cookie` ALTERNATIVE + forms ALTERNATIVE → `otp-identifier-form` REQUIRED + `otp-channel-choice-form` REQUIRED) and the same authenticator config (codeLength 6, ttl 300, maxRetries 3, phoneAttribute `phoneNumber`). Only the alias prefix differs. |
| Login themes | aggregator local ships **both** `otp` and `signals`; signals local ships only `otp` |

The one behavioural consequence to be aware of: signals' flows
(`bluedots-otp-*`) do **not** exist in the merged realm, so `signals-ui` inherits
the realm-default `aggregator-otp-browser`. Because the two flows are
execution-for-execution identical, this is equivalent — but the flow **names**
then read as aggregator-specific in a realm shared by both DPGs.

Recommend a **cosmetic rename to neutral aliases** (`otp-browser` / `otp-forms`)
while building this repo's copy, since this repo owns the file and no existing
deployment references the signals aliases. Handle with care: `aggregator-portal`
binds its browser flow by **pinned UUID**, not alias
(`authenticationFlowBindingOverrides.browser = 9f3b1c52-…`), so renaming aliases
must not disturb that id, and the id must stay unique per Keycloak server.

`aggregator-portal` is the only client with a flow-binding override, which is what
keeps the entitlement gate scoped to the portal and off signals' login path.

Two properties make the file directly usable as a chart artefact:

1. The realm name is a placeholder (`__KEYCLOAK_REALM__`) substituted by
   `render-realm.sh`, which the existing `realm-renderer` initContainer already
   runs. No hardcoded realm name, no template change.
2. All secrets are placeholders substituted at boot, and `render-realm.sh` fails
   hard on any unset one — so committing this file commits no secrets, and a
   missing one is a loud failure rather than a silent default.

The per-client theme override is what makes one shared realm acceptable to
product: signals users get the signals login page, aggregator coordinators get the
aggregator one, from a single realm.

### 5.2 The production-hardening transform (do not copy verbatim)

These files configure **developer laptops**, so copying them unchanged would ship
dev affordances to production. Apply on the way in:

**H1 — strip localhost redirect URIs and web origins.** Both browser-facing
clients carry them:

| Client | Dev entries present |
|---|---|
| `aggregator-portal` | `http://localhost:3000/api/auth/callback`, `http://localhost:3100/api/auth/callback`, `http://localhost/api/auth/callback`; web origins `http://localhost:3000`, `http://localhost:3100`, `http://localhost` |
| `signals-ui` | `http://localhost:5173/*`, `http://localhost:2742/*`; web origins `http://localhost:5173`, `http://localhost:2742` |

In a real environment these widen a production OAuth client's redirect allow-list
and its CORS origins for no benefit. The deployment realm should carry only the
`__PUBLIC_BASE_URL__` entries. Assert this in CI (§10) — it is the single
highest-value content check, because it is a security property and it is invisible
in a working deployment.

**H2 — no test users.** The deployment realm carries exactly the two service
accounts and nothing else. The current chart realm's `testuser` and `alice` are
dropped by this rewrite; the assertion in §10 stops them coming back.

**H3 — confirm `sslRequired`.** A realm created by import inherits whatever the
file says; production must not end up on a permissive value that was set to make
local HTTP work.

### 5.3 Secrets surface — six client secrets, not three

`render-realm.sh` substitutes 18 placeholders. Six are client secrets, and only
three exist in this repo's secret plumbing today:

| Placeholder | Existing key | Status |
|---|---|---|
| `__AGGREGATOR_API_SECRET__` | `KEYCLOAK_ADMIN_CLIENT_SECRET` | exists |
| `__AGGREGATOR_PORTAL_SECRET__` | `OIDC_CLIENT_SECRET` | exists |
| `__AGGREGATOR_BFF_SECRET__` | `BFF_SERVICE_CLIENT_SECRET` | exists |
| `__SIGNALS_API_SECRET__` | — | **new** — signals' `KEYCLOAK_API_CLIENT_SECRET` |
| `__SIGNALSTACK_CLIENT_SECRET__` | — | **new** — the `aggregator-dpg` client (Phase C) |
| `__VOICE_DPG_SIGNALS_SECRET__` | — | **new** — the `voice-dpg` client |

The remaining twelve are the SMTP block (9), `__BRAND_LONG_NAME__`,
`__KEYCLOAK_REALM__` and `__PUBLIC_BASE_URL__` — all already available as
non-secret config, but note SMTP is configured **both** by realm import and by
`apply-user-profile.sh`; keep them consistent or the Job will overwrite the
imported values.

Add the three new secrets to the `random_passwords` / `output-file` OpenTofu
modules so they land in the generated `global-secrets.yaml`, and generate each
**once** — `__SIGNALS_API_SECRET__` is consumed by both the realm render in
`common-services` and signals' api in the `signals` namespace.

## 6. Phase P1 — build the `common-services` Keycloak subchart

Additive only. Nothing is removed and no existing environment changes behaviour
until P2, so P1 can land and be reviewed on its own.

**P1.1 — move the subchart.**
`git mv helm/aggregator/charts/keycloak helm/keycloak/charts/keycloak` (see the correction in §9 — NOT under `common-services/charts/`).
Register it in `helm/common-services/Chart.yaml` alongside the other
dependencies, gated the same way:

```yaml
  - name: keycloak
    version: 0.1.0
    repository: file://charts/keycloak
    condition: keycloak.enabled
```

**P1.2 — build this repo's realm.**
Delete `files/aggregator-realm.json`. Create
`helm/common-services/charts/keycloak/files/realm.json` from the merge in §5.1
(copy the aggregator local realm, confirm signals' contribution is present) and
then apply the §5.2 hardening transform — strip localhost redirects/origins, no
test users, check `sslRequired`. Optionally rename the OTP flow aliases to neutral
names, preserving the pinned portal-gate flow id.

Update `templates/configmap-realm.yaml` to emit the new filename, and the
`realm-renderer` initContainer's expected input path in `deployment.yaml`.

This step fixes D1: all 7 clients, the 3 realm roles including `org_owner`, both
service accounts, the per-client theme override, the portal-gate flows, the
templated realm name — and no `testuser`/`alice`.

**P1.3 — bring in the init scripts.**
Move `helm/aggregator/files/apply-user-profile.sh` →
`helm/common-services/charts/keycloak/files/`, replacing its contents with the
536-line version from the aggregator repo's local setup. That version is a
**verified functional superset** of signals' 232-line one: it applies the
acting-org claim mappers to the identical call sites (`signals-ui` plus a loop
over the service clients), covers the same `phoneNumber` /
`unmanagedAttributePolicy` / `signals_acting_orgs` surface, and additionally
handles `aggregator_id`, `org_owner` and `ensure_login_theme signals-ui signals`.
So this is also copy-and-verify, not a hand-merge.

Add `apply-portal-gate.py` from the same directory — absent from this repo today.

**P1.4 — move the init Job into the subchart.**
`helm/aggregator/templates/{job-keycloak-init,configmap-keycloak-init}.yaml` →
`helm/common-services/charts/keycloak/templates/`. Changes required:

- Rename helpers from the `aggregator.*` namespace to `keycloak.*` /
  `platform.*`; the Job currently uses `aggregator.fullname`,
  `aggregator.secretName`, `aggregator.keycloakInternalUrl`.
- Run both scripts, in order, in one container:
  `sh /init/apply-user-profile.sh && python3 /init/apply-portal-gate.py`.
  Add `python3` to the `apk add` line.
- `apply-portal-gate.py` reads `KC_ADMIN_*`, not `KC_BOOTSTRAP_*` — supply both
  names.
- Keep it a `post-install,post-upgrade` hook. It must stay idempotent: realm
  import only applies to an empty realm, so on every subsequent boot these
  scripts are the only thing that reconciles realm state.
- The SMTP `configMapKeyRef` currently points at the aggregator global ConfigMap.
  Repoint at the `common-services` equivalent, or pass SMTP values directly from
  `platform` values.

**P1.5 — fix the hardcoded realm in the rate-limit path (trap 4.3).**
In the subchart, derive the realm from the shared global instead of a local
default:

```yaml
loginRateLimit:
  realm: ""   # empty ⇒ template falls back to .Values.global.keycloakRealm
```

Update `otp-ratelimit-ingress.yaml` to use
`{{ $rl.realm | default .Values.global.keycloakRealm }}`. Without this the login
rate limit fails open the moment the realm is not literally `aggregator`.

**P1.6 — theme + SPI image.**
The subchart already supports a `themesInit` initContainer image
(`ghcr.io/blue-dots-economy/aggregator-dpg/keycloak-theme`). Because the shared
realm points `signals-ui` at a `signals` login theme, **the image must contain
both `otp` and `signals` themes** or signals logins render the wrong brand.
`aggregator-dpg/infra/keycloak/themes/` carries both and
`build-theme-image.sh` builds per network — so no new build tooling is needed,
but the image tag in `global-images.yaml` must be one built after the `signals`
theme landed. Treat "theme image predates the signals theme" as a release gate.

**P1.7 — decouple the Keycloak DB.**
In `helm/common-services/values.yaml`, change the `keycloak` database entry's
owner from `aggregator` to a dedicated `keycloak` role, and add that role to the
bootstrap SQL with its own generated password. Existing environments keep the
`aggregator` owner — see P6.3; do not attempt an in-place owner change as part of
this move.

**P1.8 — values surface.**
Add a `keycloak:` block to `helm/common-services/values.yaml` with
`enabled: true` and the settings promoted from the old aggregator values. Move
replica/HPA/PDB/resource entries to `helm/global-resources.yaml` under the
`keycloak` key, matching how every other workload in this repo is sized.

## 7. Phase P2 — cut the aggregator chart over

**P2.1** — remove the `keycloak` dependency from `helm/aggregator/Chart.yaml` and
delete the now-moved templates.

**P2.2** — repoint the helpers in `helm/aggregator/templates/_helpers.tpl`:

| Helper | Now | After |
|---|---|---|
| `aggregator.keycloakInternalUrl` | in-namespace `…-keycloak` service | `http://common-services-keycloak.common-services.svc.cluster.local:8080/auth` |
| issuer (`_helpers.tpl:71`) | `<publicBaseUrl>/auth/realms/<realm>` | unchanged — the public URL does not move |

The issuer staying identical is what makes this a low-risk cutover: tokens,
redirect URIs and the `aggregator-portal` client config are all keyed on the
public URL, which continues to be served by Kong from `common-services`.

**P2.3** — make both URLs overridable rather than derived-only, so a deployment
that keeps a local Keycloak during migration can point at it without a chart
change.

**P2.4** — secrets. `helm/aggregator/templates/secrets.yaml` guards
`KC_BOOTSTRAP_ADMIN_PASSWORD` and the Keycloak client secrets through
`aggregator.requireSecret`. The bootstrap admin password now belongs to
`common-services`; the **client** secrets are still needed by aggregator-api/web.
Split accordingly:

- `common-services` secret: `KC_BOOTSTRAP_ADMIN_PASSWORD`, plus every
  `__*_SECRET__` value `render-realm.sh` substitutes into the realm — including
  the **signals** client secrets, because the realm that defines those clients is
  now rendered here.
- `aggregator` secret: keeps `OIDC_CLIENT_SECRET`, `BFF_SERVICE_CLIENT_SECRET`,
  `KEYCLOAK_ADMIN_CLIENT_SECRET`.

The same client secret is therefore consumed in two namespaces and must be
generated once in `global-secrets.yaml` and referenced from both. Keep the
`requireSecret` guard on both sides — it is what stops a `change-me` default
reaching a cluster.

**P2.5** — the aggregator NetworkPolicy is Ingress-only with unrestricted egress,
so cross-namespace calls to Keycloak keep working. But `common-services` must be
listed in the aggregator's `networkPolicy.allowedFromNamespaces` for the init Job
and any Keycloak-initiated callback. Verify with a live `dry_run`, since CI does
no Helm validation.

## 8. Phase P3 — wire signals

`helm/signals/` has no Keycloak surface at all. Add one to the `api` and `ui`
subchart ConfigMaps.

**P3.1 — `api` ConfigMap.** Emit, all from `global.*` so the two DPGs cannot
disagree:

| Env | Source |
|---|---|
| `AUTH_PROVIDER` | `global.authProvider` — `betterauth` or `keycloak` only |
| `KEYCLOAK_BASE_URL` | public issuer base, `<publicBaseUrl>/auth` |
| `KEYCLOAK_INTERNAL_BASE_URL` | in-cluster service URL |
| `KEYCLOAK_REALM` | `global.keycloakRealm` |
| `KEYCLOAK_UI_CLIENT_ID` | `signals-ui` |
| `KEYCLOAK_API_CLIENT_ID` | `signals-api` |
| `KEYCLOAK_ACCEPTED_CLIENT_IDS` | `signals-ui` — **load-bearing** |
| `KEYCLOAK_REQUIRED_REALM_ROLES` | per the app default |
| `KEYCLOAK_SERVICE_CLIENT_IDS` | `aggregator-dpg` when Phase C lands; empty otherwise |
| `KEYCLOAK_API_CLIENT_SECRET` | signals namespace secret |

`AUTH_PROVIDER` accepts only `betterauth` or `keycloak` — `dual` was removed in
signals Phase 4, and the app raises an actionable error if it sees it. So the
chart must never offer `dual`, and **the cutover per environment is a hard flip,
not a ramp.** That is the single most important sequencing fact in this plan.

**P3.2 — `ui` subchart.** `VITE_KEYCLOAK_*` are Vite build-time vars, but
`apps/ui/src/lib/keycloak-config.ts` treats them as *overrides* over runtime
config fetched from the api. So the UI needs **no image rebuild** per
environment — leave the `VITE_*` vars unset and let the api supply the values.
This is the opposite of the aggregator `NEXT_PUBLIC_API_URL` situation and worth
stating explicitly, because assuming a rebuild is needed would add a build step
to every environment for nothing.

**P3.3 — `KEYCLOAK_ACCEPTED_CLIENT_IDS` must stay `signals-ui` only.** It is the
only thing stopping an `aggregator-portal` token being honoured on signals' human
session path. Never widen it to include aggregator clients, and never include
`signals-api` (a confidential service client, deliberately excluded upstream).

**P3.4 — signals NetworkPolicy.** `common-services` must be in
`allowedFromNamespaces`; `aggregator` must stay listed, as aggregator-dpg calls
the signals API.

## 9. Phase P4 — sequencing, and the deadlock a naive subchart move causes

**This is the highest-risk part of the move and it is not obvious.**

The `keycloak` database is created by `postgres-bootstrap-job`, which is a
`post-install,post-upgrade` **hook** at weight `0`
(`helm/common-services/templates/postgres-bootstrap-job.yaml:26`). And
`deploy_common_services` runs `helm upgrade --install … --wait --timeout 5m`
(`install.sh:211`).

Helm's order with `--wait` is: install main resources → **wait for them to become
Ready** → *then* run post-install hooks. So if the Keycloak Deployment is a plain
subchart resource of `platform`:

1. Helm creates the Keycloak Deployment as a main resource.
2. `--wait` blocks until it is Ready.
3. Keycloak crash-loops, because the `keycloak` database does not exist yet.
4. The post-install hook that would `CREATE DATABASE keycloak` **never runs**.
5. The release fails at the 5-minute timeout.

This works today only because Keycloak lives in a *later, separate release*
(`aggregator`), by which point common-services' hooks have long finished. Moving
it into the same release as its own database bootstrap introduces a circular wait.

Two ways out:

**Option A (recommended) — Keycloak as its own release in the `common-services`
namespace.** Deploy it via a new `deploy_keycloak()` that runs *after*
`deploy_common_services` and *before* `deploy_signals`.

**Correction found during implementation:** the chart must NOT live under
`helm/common-services/charts/`. Helm renders **every** chart in a `charts/`
directory, whether or not it is listed in `Chart.yaml` `dependencies` — so placing
it there reintroduces the deadlock even with no dependency entry and no condition
to gate it. It is therefore a top-level chart at `helm/keycloak/`, structured as a
thin umbrella (`charts/keycloak/` inside it) so the existing `keycloak:` key in
`global-resources.yaml` and `global-values.yaml` keeps working unchanged. Hook semantics stay untouched, the ordering stays
explicit and readable, and it matches how this repo already sequences
dependencies — strict order between releases rather than magic within one. It is
still a common service: one instance, `common-services` namespace, both DPGs
consume it.

**Option B — true subchart, with a self-bootstrapping initContainer.** Add an
initContainer to the Keycloak Deployment that connects with the Postgres master
credentials and creates the database if absent, removing the dependency on the
hook. Satisfies "subchart of `platform`" literally, but duplicates DB-creation
logic that already exists in the bootstrap job and hands Keycloak master
credentials it otherwise never needs.

Take Option A unless there is a specific reason Keycloak must be inside the
`platform` release.

**P4.1 — deploy order.** `deploy_all_services` becomes: preflight → namespaces +
secrets → monitoring → common-services → **keycloak** → signals → aggregator →
`fix_acme_issuer_uri`. Keycloak before signals matters because signals' api
asserts its Keycloak config at boot when `AUTH_PROVIDER=keycloak`; it does not
matter for the realm contents, since the realm defines signals' clients without
needing signals to exist.

The existing `actingOrgId` manual step between signals and aggregator is
unaffected and still required.

**P4.2 — hook weights.** If Option B is taken, the Keycloak init Job must not sit
at weight `5` — `postgres-extensions-job` already uses `5`, and Helm's ordering
between equal weights falls back to name sorting rather than anything meaningful.
Use `10` or higher so realm reconciliation is unambiguously last.

**P4.3 — `lint` / `dry_run` / CI.** `helm lint` currently passes
`--set global.existingSecret=lint-only` for the aggregator chart only, to satisfy
the `requireSecret` guard. Once the Keycloak secrets move, `common-services` (or
the new keycloak release) needs the equivalent placeholder in `lint()`,
`dry_run()` and `.github/workflows/ci.yml`. Without it the helm job starts failing
on the render.

**P4.4 — teardown.** `destroy_aggregator` and `cleanup_all_services` currently
take Keycloak down with the aggregator release. After the move, deleting the
`common-services` namespace destroys the Keycloak Postgres data along with it —
already true for the DB, but the blast radius is now "all identity for both DPGs"
rather than "aggregator only". Update the destructive-operation warnings in
`DEPLOYMENT.md` accordingly.

## 10. Phase P5 — content assertions and the re-merge procedure

Under §3.1 there is no canonical upstream to diff against — the app repos'
`infra/keycloak/` trees are independent local setups, and this repo owns its
deployment realm. So a "drift from upstream" check would be wrong: it would flag
intentional differences (the hardening transform in §5.2 guarantees the files
differ) and would couple a deployment artefact to a dev artefact.

Replace it with two things.

**P5.1 — self-contained content assertions in CI.** No network, no app-repo
checkout. Fail the build if the realm file does not satisfy:

| Assertion | Catches |
|---|---|
| No `localhost` / `127.0.0.1` in any `redirectUris` or `webOrigins` | H1 regressing — the highest-value check, because it is a security property and invisible in a working deployment |
| `users[]` contains exactly the two service accounts | `testuser` / `alice` returning |
| `roles.realm[]` contains `org_owner`, `signals_participant`, `signals_admin` | D1 — the current defect that breaks org approval |
| All 7 expected client ids present | a partial copy |
| `signals-ui` carries `login_theme: signals` | signals logins silently rendering the aggregator brand |
| Exactly one client has `authenticationFlowBindingOverrides`, and it is `aggregator-portal` | the entitlement gate leaking onto signals' login path, or falling off the portal |
| Every `__PLACEHOLDER__` in the file has a corresponding secret/config key wired | a render-time hard failure at deploy instead of at CI |
| `.realm` is `__KEYCLOAK_REALM__`, not a literal | a hardcoded realm name |

These are worth more than any diff: they encode the properties that must hold,
and they also catch a bad hand-edit made directly in this repo.

**P5.2 — a documented re-merge procedure.** The realm needs updating when either
app repo changes its Keycloak setup in a way that affects deployment — a new
client, role, mapper, flow or theme. That is a human trigger, not something CI can
detect, so it needs to be written down rather than automated:

- Record in the chart README which app-repo commit each merge was taken from, so
  the next person knows the baseline.
- The procedure is §5.1 (compare both repos' realms, take the superset) followed by
  §5.2 (re-apply the hardening transform), then the P5.1 assertions.
- Add it to the app repos' PR checklist as a reminder — "does this change the
  deployed realm?" — since the change originates there even though the work lands
  here.

Optionally add a **non-blocking advisory** CI job that fetches both app repos'
realms and reports added/removed clients, roles and mappers relative to this
repo's copy. Useful as a nudge; it must not gate, or intentional hardening
differences will fail every build.

## 11. Phase P6 — upgrade path for existing deployments

Applies to the live deployment branches — as of 2026-07 `blue-dots-prod`,
`orange-dot-prod`, `private-cluster`. Treat
`git ls-remote --heads origin` as the source of truth, not that list.

Each of these runs a Keycloak **in the `aggregator` namespace, with real
coordinator users in its `keycloak` database**. The move must not lose them.

### 11.1 What actually has to move — and what does not

The **database does not move.** The `keycloak` database already lives in the
shared `common-services` Postgres (or RDS), not inside the aggregator release —
the aggregator release owns only the Keycloak *Deployment*. So the workload
relocation half is genuinely cheap: point a new Keycloak Deployment in
`common-services` at the same `keycloak` database and every user, credential,
client and realm row is already there. There is **no cross-server user
migration** and no `pg_dump`-and-restore of identity data.

What is *not* free is the realm itself: its name is wrong and its contents are the
stale 2-client version. That is the actual work, and §11.2 covers it. Keep the two
halves separate in your head — the Deployment move is low-risk, the realm
migration is not.

### 11.2 The deployed realm must be migrated, not just renamed

Existing deployments were provisioned from the stale chart realm. Their realm is
named **`aggregator`** and — critically — its *contents* are the 2-client,
0-role version from D1. The target is the merged realm from §5.1 under the common
name. So the migration has two independent halves:

| Half | Gap |
|---|---|
| **Name** | `aggregator` → the common realm name (network/domain-derived) |
| **Contents** | 5 missing clients (`aggregator-bff`, `signals-ui`, `signals-api`, `aggregator-dpg`, `voice-dpg`), 2 missing roles (`signals_participant`, `signals_admin`), the missing `service-account-signals-api`, the per-client theme override, and the portal-gate flows |

**The contents half is the real work, and `--import-realm` cannot do it.** Realm
import applies only to an *empty* realm, so on an existing realm it is skipped
entirely. Anything additive has to go through the admin REST API.

And the current init script only partly covers it. Verified against the 536-line
version:

- ✅ **creates `org_owner`** if absent, and grants
  `realm-management:manage-realm` to the API service account — both idempotent
- ❌ **does not create clients.** `ensure_acting_org_mapper` logs
  `client '<id>' not found — skipping` and `return 0` — it *silently succeeds*
- ❌ **does not create** `signals_participant` / `signals_admin`
- ❌ **does not create** `service-account-signals-api`

So a naive "deploy the new chart and let the init Job reconcile" leaves the realm
without any signals client, and the init Job **exits 0** while doing so. That is
the failure mode to design against: it looks like a clean deploy.

### 11.2.0 RESOLVED — Path A, minus the rename

**Path A stands: the new unified realm is created fresh and users are copied into
it with ids preserved.** Two corrections to it, both from implementation:

1. **No realm is renamed.** Path A below renames the existing realm aside to free
   the target name. That is unnecessary — the unified realm name *differs* from the
   existing one, so `--import-realm` simply creates it alongside. Verified: the
   previously-deployed chart realm pins no authentication-flow ids, so the new
   realm's pinned entitlement-gate flow cannot collide with it.

2. **The credential-count pre-flight is dropped.** These realms are OTP-only, so
   there are no password credentials for the copy to lose. §6.3 of the runbook keeps
   a cheap confirmation of that premise instead.

Separately, and **additive** to the migration rather than a replacement for it,
`keycloak-init` now runs `apply-realm-config.py`, which reconciles clients, realm
roles and service-account grants in place via `partialImport`
(`ifResourceExists: SKIP`). That closes the gap the older scripts left — they
reconcile but never create, logging `client '<id>' not found — skipping` and
returning 0. It is a no-op on this migration, where the fresh import already creates
everything; its purpose is any realm that later drifts from `realm.json`. Verified
on 26.5.5: 5 clients + 3 roles added to a deliberately stale realm, idempotent on
re-run (`added=0 skipped=10`), with existing client id, service-account user id and
client secret all unchanged.

Path B was not taken. The operational procedure is
`docs/unified-keycloak-migration-runbook.md`.

### 11.2.1 Two migration paths — pick on one pre-flight fact (HISTORICAL)

Run this first; it decides the path:

```bash
# does any real user hold a password credential, or is this an OTP-only realm?
select count(*) from credential c
  join user_entity u on u.id = c.user_id
  join realm r on r.id = u.realm_id
  where r.name = 'aggregator' and c.type = 'password';
```

**Path A — recreate the realm and re-import users. Recommended if that count is 0.**

Rename the existing realm out of the way (e.g. to `aggregator-legacy`), let
Keycloak import the merged realm fresh under the target name, then re-import the
users with their ids preserved.

Why this is the better path when credentials allow it: the deployed realm ends up
**byte-equivalent to the chart's `realm.json`**. That is the entire point of this
repo owning the artefact — otherwise every environment carries a hand-reconciled
realm that differs from the file, and the P5.1 assertions guarantee nothing about
what is actually running. It also needs **no net-new reconciler**, and it leaves
the legacy realm intact beside the new one as an instant rollback.

Constraints to respect:
- `POST /users` ignores a supplied id; **`partialImport` honours it**. Use
  `partialImport` — preserving `sub` is non-negotiable, because it is persisted in
  the aggregator DB (`aggregator_orgs.owner_kc_sub`, `bulk_uploads.uploaded_by`,
  `registration_links.created_by`, `aggregators.created_by`/`updated_by`).
- Carry over the user **attributes** too — `aggregator_id`, `decision_made`,
  `signalstack_org_id` — or approved coordinators are refused at the portal gate.
- Two realms coexist briefly, so the pinned portal-gate flow id must not collide
  with anything in the legacy realm. Verify per environment before starting.
- Verify a `partialImport` round-trip on a **copy** of the database first. Do not
  trust it on a live realm untested.

**Path B — rename in place and write the missing reconciler.** Required if
password credentials exist, since those are the thing an export/import round-trip
is most likely to lose.

- The rename itself is a single `PUT /admin/realms/{realm}` with a changed
  `.realm` field. This was **tested against Keycloak 26.5.5** (the pinned version):
  it returns 204, the old name 404s, the new name serves OIDC discovery, every
  user id is preserved byte-for-byte, a token mints under the new issuer with the
  same `sub`, and Keycloak also renames the `<realm>-realm` admin client in
  `master` — i.e. it runs a dedicated rename path, not an incidental field update.
  Note it is undocumented upstream and the admin console does not expose it.
- Then extend the init script with idempotent `ensure_client` / `ensure_realm_role`
  / `ensure_service_account` functions covering the §11.2 contents gap. This is the
  net-new work Path A avoids. It must be non-destructive on an existing client —
  reconcile secret and mappers, never delete and recreate, or the client's
  service-account user id changes.

Either way the rename invalidates every session and SSO cookie, so coordinators
re-login. Flush the web session store (`session:*` in the aggregator Redis) as part
of the window so users get a clean re-login rather than an opaque failure.

### 11.2.2 The silent-lockout guard

Realm import applies only to an empty realm. So if `global.keycloakRealm` names a
realm that does **not** exist, Keycloak creates a new empty one and the Deployment
comes up **healthy with zero users**. Nothing fails at boot; the apps simply reject
every login while the old realm sits untouched beside it.

Guard explicitly, because no existing check catches it:

- Assert the configured realm name matches a row in `realm` *before* deploying.
- Add a `deploy_keycloak` preflight that fails when the configured realm exists but
  holds no user carrying an `aggregator_id` attribute while `aggregators` is
  non-empty.
- In the deploy log, confirm the import was **skipped**, not performed. An import
  line on a supposedly-existing realm means you are in this failure mode.

**The dangerous failure to design against:** realm import only applies to an
*empty* realm. If `global.keycloakRealm` is set to a name that does not exist in
the database, Keycloak creates a **new, empty realm** and the new Deployment comes
up healthy with zero users. Nothing fails at boot — the apps just reject every
login, and the old realm sits untouched beside the new one. Guard against it:

- Assert the configured realm name matches a row in `realm` *before* deploying.
- Add a preflight check to `deploy_keycloak` that fails when the configured realm
  exists but contains no users carrying an `aggregator_id` attribute while the
  `aggregators` table is non-empty.

### 11.3 Per-environment sequence

1. **Back up** the `keycloak` database (`pg_dump`). This is the rollback.
2. **Record a baseline** to compare against afterwards. Key on the realm **name**,
   resolving the realm id at query time — `realm.id` is a **UUID**, not the realm
   name, so any check written as `where realm_id = 'aggregator'` returns zero rows
   and passes vacuously:
   ```sql
   select count(*) from user_entity
     where realm_id = (select id from realm where name = '<realm>');
   ```
3. **Run the credential count** (11.2.1) and choose Path A or Path B. Record which,
   in the deployment branch, so the next operator is not guessing.
4. **Announce the window.** The realm name changes on both paths, so every session
   and SSO cookie is invalidated and all coordinators must re-login.
5. **Set `global.keycloakRealm`** to the target common realm name.
6. **Deploy `common-services`** (adds the new secrets and the `keycloak` role;
   Keycloak itself not yet running there).
7. **Scale the aggregator Keycloak to zero** — do not delete it. Keeping it as a
   scaled-down rollback target is far cheaper than a database restore.
8. **Execute the chosen path** (11.2.1) — rename-out + fresh import + user
   `partialImport`, or rename-in-place + reconciler.
9. **`deploy_keycloak`.** On Path A confirm the import **ran** against the empty
   target realm; on Path B confirm it was **skipped**. The wrong one for your path
   means you are in the 11.2.2 failure mode — stop.
10. **Re-run the baseline queries.** User counts and the three attribute counts
    must match pre-migration exactly.
11. **Assert realm contents against the chart file** — 7 clients, 3 roles, both
    service accounts present in the *running* realm, not just the file. This is the
    check that catches the silent `client not found — skipping` path.
12. **Flush the web session store** — `session:*` in the aggregator Redis — so
    users get a clean re-login instead of an opaque failure on a stale token.
13. **Deploy signals with `AUTH_PROVIDER` still `betterauth`.** The chart wiring
    lands inert. Do not flip in the same step.
14. **Deploy aggregator** repointed at the common Keycloak. Verify a real
    coordinator login end-to-end and `/profile` rendering (a
    `403 MISSING_AGGREGATOR_ID` means the `aggregator_id` mapper or attribute did
    not survive — check the init Job logs).
15. **Only then, as a separate window, flip signals to
    `AUTH_PROVIDER=keycloak`.** There is no `dual` mode, so this is a hard cutover
    and every signals user must already exist in the realm. That user-provisioning
    prerequisite belongs to signals-dpg — see §12.
16. **Delete the legacy realm and the old aggregator Keycloak** once both DPGs are
    verified and you are past the rollback window.

### 11.4 Ownership loose end

Existing environments have the `keycloak` database owned by the `aggregator` role
(P1.7). Leave it. Changing the owner of a live database is not worth the risk for
a cosmetic gain; the new owner applies to new environments only. Note the
divergence in the deployment branch's README so it is not mistaken for drift.

## 12. Dependencies outside this repo

No app-repo *code* changes are needed (§3.1). These are the non-code
prerequisites this plan cannot satisfy from here:

| Dependency | Where | Blocks |
|---|---|---|
| Every existing signals user provisioned into the shared realm | signals-dpg operational task | P6 step 15. `dual` was removed, so there is no just-in-time backfill during cutover — the flip is all-or-nothing. |
| Keycloak image containing **both** `otp` and `signals` themes plus the OTP SPI jar | image build | P1.6. Signals logins render the aggregator brand otherwise. The image is currently built from the aggregator repo (`aggregator-dpg/keycloak:26.5.5-aggregator`) — decide whether that build moves into this repo's `dockerfiles/`, now that this repo owns deployment. |
| A named owner for this repo's realm artefact | this repo | P5.2. Someone has to run the re-merge when either app repo's Keycloak setup changes. |
| `partialImport` round-trip verified on a database copy | this repo, pre-migration | P6 Path A. Do not trust it untested on a live realm. |

## 13. Verification

- `bash install.sh lint dry_run` passes, including the new placeholder-secret
  flags (P4.3).
- The rendered realm ConfigMap contains 7 clients, `org_owner`, and exactly two
  users (P5).
- `helm list -A` shows Keycloak in `common-services`, absent from `aggregator`.
- Aggregator: real coordinator OTP login → portal → `/profile` renders. A
  `decision_made=pending` account is refused.
- Signals (post-flip): participant OIDC login, and an `aggregator-portal` token is
  **rejected** on signals' human session path (P3.3).
- Login rate limit actually matches: a burst against
  `/auth/realms/<realm>/login-actions/authenticate` gets throttled (P1.5 — this
  fails open silently if the realm name is wrong).
- One bulk upload runs end-to-end, exercising the `aggregator-api` service
  account.

## 14. Risks

| Risk | Mitigation |
|---|---|
| Subchart move deadlocks the `common-services` release | Option A in §9 — separate release, unchanged hook semantics |
| **Init Job "succeeds" having created no signals client** — `client not found — skipping` returns 0 | Assert running-realm contents, not just the file (P6 step 11); Path A avoids the reconciler entirely (11.2.1) |
| Empty realm created silently; all users locked out with a healthy pod | Realm-name preflight + baseline counts + import-skipped/ran check (11.2.2) |
| `sub` not preserved, orphaning aggregator DB ownership columns | `partialImport` (not `POST /users`), verified on a DB copy first (11.2.1 Path A) |
| User attributes lost, so approved coordinators are refused at the gate | Carry `aggregator_id`, `decision_made`, `signalstack_org_id`; verify a real login (P6 step 14) |
| Localhost redirect URIs / web origins reach production | Hardening transform H1 + CI assertion (§5.2, P5.1) |
| Deployed realm silently diverges from the chart file | Path A makes them equivalent by construction; P5.1 asserts the file; step 11 asserts the realm |
| Realm artefact goes stale as app repos evolve | Named owner + re-merge procedure + advisory job (P5.2, §12) |
| Login rate limit fails open after the realm name changes | Derive from `global.keycloakRealm` (P1.5) |
| Signals flip with unprovisioned users | Hard prerequisite, separate window (P6 step 15, §12) |
| Three new client secrets missing at render time | Add to `random_passwords`/`output-file`; `render-realm.sh` fails hard, so this is loud (§5.3) |
| One shared secret consumed in two namespaces gets out of sync | Generate once in `global-secrets.yaml`, reference from both (P2.4, §5.3) |
| `common-services` teardown now destroys both DPGs' identity | Update destructive warnings in `DEPLOYMENT.md` (P4.4) |

