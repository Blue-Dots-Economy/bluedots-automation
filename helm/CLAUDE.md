# CLAUDE.md — helm (application deployment)

Guidance for the Helm half of the repo. Read the root `CLAUDE.md` first (the critical directory/chart/release/namespace table, the strict deploy order, the values-file architecture). Per-chart `README.md` files (`helm/README.md`, `helm/monitoring/README.md`, etc.) cover standalone-deploy detail; this file covers the Claude-specific gotchas that span or aren't obvious from the charts.

## The five umbrella charts

- **`monitoring/`** (chart `monitoring`) — `kube-prometheus-stack` (Prometheus Operator + Prometheus + Alertmanager + node-exporter + kube-state-metrics, **and the monitoring CRDs** others depend on), `loki`, `alloy` (DaemonSet log shipper, replaced Promtail), `jaeger`, Grafana (`_grafana_host`). The stock kube-prometheus ruleset is **disabled** (`defaultRules.create: false`) — alerting is a curated `additionalPrometheusRulesMap`. See `helm/monitoring/README.md`.
- **`common-services/`** (chart `platform`) — Kong ingress, cert-manager + `letsencrypt-prod` issuer, shared Postgres (disabled by default when RDS is used), Redis, metrics-server. Passwords generated on first install into `data-postgres`/`data-redis` Secrets in the `common-services` namespace. The Bitnami `postgresql` subchart runs the org **portable-pgvector** image (`ghcr.io/blue-dots-economy/postgres-pgvector`, #93) — a Postgres + pgvector + PostGIS build compiled without AVX-512 so it doesn't SIGILL on non-AVX-512 nodes; it needs the `image.*` override plus `allowInsecureImages`, since the Bitnami chart otherwise refuses a non-Bitnami image.
- **`signals/`** (chart `dpg`) — api, ui, notification-service, search (+ search-embeddings), s3-export. Connects to the shared DBs in `common-services`. The `match-score` subchart (the external dpg-scoring service) was removed in #89 — match-score now calls signals-search `POST /v1/relevance`. The **`s3-export`** subchart (chart `dpg-s3-export`, #86) is a CronJob that dumps allowlisted **non-PII** Signals data to S3 for campaign analytics.
- **`keycloak/`** (chart `keycloak-platform`) — the **shared** Keycloak. One instance, one realm, **both DPGs' clients**. Its own release in the `common-services` namespace (see the deadlock note below). Owns this repo's realm artefact (`charts/keycloak/files/realm.json`) plus the two realm-reconciliation scripts.
- **`aggregator/`** (chart `aggregator-dpg`) — web (BFF), api, worker. Vendored `ingress-nginx`/`cert-manager` subcharts are **disabled** (`platform` owns them). Keycloak is no longer here.

Resource requests/limits (Kong `replicaCount: 2`, cert-manager, Redis, `postgresBootstrap`, metrics-server, app replicas/HPA/PDB) live in the shared `helm/global-resources.yaml`, not per-chart values.

## Shared Keycloak — the things that will bite you

**It is a separate release on purpose.** The `keycloak` database is created by
common-services' `postgres-bootstrap-job`, a **post-install hook** (weight 0), and
`deploy_common_services` runs `helm upgrade --install … --wait`. Helm installs main
resources, waits for Ready, and only *then* runs post-install hooks. A Keycloak
Deployment inside that release would crash-loop on the missing database while the
hook that would create it never runs → the release deadlocks and times out at 5m.
Also note Helm renders **every** chart in a `charts/` directory, not just those
listed as `dependencies` — so simply dropping the chart under
`common-services/charts/` reintroduces the deadlock even without a dependency
entry. Hence `helm/keycloak/` as a top-level chart, deployed by `deploy_keycloak`
between common-services and signals.

**The realm is this repo's artefact, not a mirror.** `infra/keycloak/` in
aggregator-dpg and signals-dpg are independent **developer-local** setups. They are
not upstream of this repo and are *supposed* to differ from what deploys. Build
with `scripts/build-realm.sh <app-repo realm.json>` (applies the hardening
transform) and gate with `scripts/assert-realm.sh` — which CI runs. Do **not** add
a "drift from upstream" diff; it would fail on the intentional differences.

**Two hardening steps that are invisible when they regress:**
- The local realms carry `localhost` entries in `redirectUris`, `webOrigins` and —
  easy to miss — the `##`-delimited `post.logout.redirect.uris` *attribute*. Those
  widen a production OAuth client's allow-lists. `assert-realm.sh` fails on any of
  them.
- `sslRequired` is `external`, not `all`: Keycloak exempts **private** source
  addresses, so the in-cluster init Job keeps working over plain HTTP while
  external callers must use HTTPS. A `kubectl port-forward` session comes from a
  non-private address and gets `403 HTTPS required` — expected, not a fault.

**signals-ui lives on different hostnames to Keycloak.** `__PUBLIC_BASE_URL__` is
the Keycloak/aggregator host; the signals UI is served from `global.publicHosts` (a
**list**). Substituting the Keycloak host into signals-ui's allow-lists fails login
with `invalid_redirect_uri` in any real deployment — and works fine locally, where
both are localhost. `render-realm.sh` therefore rewrites signals-ui's
redirect/origin/post-logout fields from `SIGNALS_ORIGINS` (built by Helm from
`global.publicHosts`). If that is empty the script warns and leaves the
single-host fallback.

**The realm name has no literal default anywhere.** `global.keycloakRealm` is
required and consumed by three charts (keycloak, aggregator, signals) — they must
agree or tokens validate against the wrong issuer. It is also the realm segment of
the Kong login-rate-limit route, which is now *derived*: it used to be a hardcoded
`loginRateLimit.realm: aggregator`, so after any rename that route matched nothing
and the per-IP login limit **failed open silently**.

**Secrets are shared across namespaces by design.** The keycloak release RENDERS
the realm that defines the clients; the aggregator and signals AUTHENTICATE against
them. So the client secrets must be one value each — generated once in
`global-secrets.yaml` and referenced from both. Watch two traps: the keycloak chart
reads `secrets.keycloakPostgresPassword` (**not** `secrets.postgresPassword`, which
is the aggregator database password in that same shared root block), and
`secrets.signalsApiSecret` must equal signals' `KEYCLOAK_API_CLIENT_SECRET`.

**The init Job reconciles realm CONTENTS in place — step order is load-bearing.**
It runs four steps: render the realm (reusing the pod's own `render-realm.sh`, so
the substitution cannot differ), then `apply-realm-config.py`, then
`apply-user-profile.sh`, then `apply-portal-gate.py`.

`apply-realm-config.py` must stay **first**. The two scripts after it reconcile but
never CREATE a client — `ensure_acting_org_mapper` and `ensure_login_theme` both log
`client '<id>' not found — skipping` and **return 0**. Run them first and a realm
predating a realm.json change keeps its missing clients while the Job still exits 0:
a silent no-op. Reconciling clients first is what makes the rest effective.

It uses Keycloak's own `partialImport` with `ifResourceExists: SKIP`, never
OVERWRITE — re-creating an existing client changes its service-account user id, and
those ids are referenced from the aggregator database. It also grants the
`realm-management` client roles each service account needs, because creating a
client with `serviceAccountsEnabled` makes the SA user but grants it nothing.

It strips `authenticationFlowBindingOverrides` before importing: a binding
references a flow by id, and importing a client whose flow does not exist yet fails
with an opaque HTTP 500. `apply-portal-gate.py` owns that binding and reconciles it
every run anyway.

**Scope: drift, not migration.** On a fresh realm import this step is a no-op —
everything already exists. Its job is a realm that has *drifted* from `realm.json`
after the fact, which is precisely what used to fail silently. Migrating an existing
environment onto the unified realm is a separate procedure
(`docs/unified-keycloak-migration-runbook.md` §6): the new realm is imported fresh
and users are copied in with ids preserved. Verified on 26.5.5: 5 clients + 3 roles
added to a deliberately stale realm, idempotent on re-run
(`added=0 skipped=10`), existing client id, service-account user id and client
secret all unchanged.

## Cluster Autoscaler (#1.6)

`common-services/templates/cluster-autoscaler.yaml` (first-party, not a vendored subchart) ships the Kubernetes Cluster Autoscaler as SA + cluster-wide RBAC + Deployment, gated by `clusterAutoscaler.enabled` (**default OFF**). It scales the EKS managed node group's ASG between the OpenTofu `node_count_min`/`node_count_max` (raised to **2 / 6** via the `_eks_node_count_min`/`_eks_node_count_max` anchors in `opentofu/aws/template/global-values.yaml` — was 1 / 2, which left no headroom; `_common/eks.hcl` reads these anchors directly, so the module defaults in `modules/eks/variables.tf` are shadowed under Terragrunt and were a no-op) via ASG auto-discovery (`--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,...`; the node group carries those discovery tags, and EKS propagates them to the ASG). AWS access is **IRSA**, not node creds: `modules/eks/main.tf` adds a `cluster_autoscaler_irsa` role (scoped `attach_cluster_autoscaler_policy`, bound to `common-services:cluster-autoscaler`) and exports **`cluster_autoscaler_role_arn`**.

**To enable per environment:** `tofu apply` (creates the IRSA role + retags the node group), then set `clusterAutoscaler.enabled: true`, `clusterAutoscaler.clusterName: <env>-cluster`, `clusterAutoscaler.awsRegion`, and `clusterAutoscaler.serviceAccount.roleArn: <cluster_autoscaler_role_arn output>` (wire the ARN through `global-cloud-values.yaml` alongside the existing `app_sa_role_arn` IRSA annotations, or set it directly), then `deploy_common_services`. Runs in the `common-services` namespace with cluster-wide RBAC. Default-off because bluedots CI runs no Helm/k8s validation — validate with a live `install.sh dry_run` first.

## Ingress is Kong, not nginx

`common-services` vendors both `ingress-nginx` and `kong` subcharts, but the committed default is **Kong** (`kong.enabled: true`, `ingress-nginx.enabled: false`). Kong (DB-less) is the sole controller and the cluster-default IngressClass; every app Ingress sets `ingressClassName: kong`. Rate limiting is `KongClusterPlugin` tiers (`rl-auth`/`rl-api`/`rl-public`) in `helm/common-services/values.yaml`, attached per route via the `konghq.com/plugins` annotation, counters in the shared Redis (`policy: redis`). DNS points public hosts at the Kong proxy LB: `kubectl -n common-services get svc common-services-kong-proxy`.

**Correlation id (#2.4).** `kong.correlationId.enabled` (default **on**) renders `templates/kong-correlation-id.yaml` — a GLOBAL `KongClusterPlugin` (`global: "true"`, like `prometheus`) that stamps `X-Request-Id` on every inbound request lacking one (an inbound value is preserved) and echoes it downstream. Downstream services honour + log it as `x-request-id` and the aggregator forwards it to Signals, so a request traces across Kong → aggregator → Signals → search. `correlation-id` is a bundled Kong plugin, so no CRD change is needed (the `KongClusterPlugin` kind is already applied by `apply_kong_crds`).

**Per-IP OTP-abuse rate limiting (#69).** `otpRateLimit.enabled` (default **on**, via `_otp_rate_limit_enabled`) renders `otp-ratelimit-ingress.yaml` in both the signals `api` and the shared `keycloak` charts — a more-specific Kong Ingress on the OTP endpoints with a per-IP `rate-limiting` KongPlugin (counters in shared Redis). Limits: `_signals_otp_per_minute` (default 5) and `_aggregator_otp_per_minute` (default 20). Independent of the global per-API rate limit (`_api_rate_limit_*`, default off). Bundled Kong plugin — no CRD change. Tightening these too far can lock out legitimate logins.

**Signals-UI SSL-redirect + HSTS (#128, Issue #10).** The signals `ui` Ingress gains `ingress.forceSSLRedirect` + `ingress.hsts.enabled` (both default **on**, no-op unless `ingressClassName` is `kong`). Redirect adds `konghq.com/protocols: "https"` + `konghq.com/https-redirect-status-code: "301"` so a plain-http request 301s to https instead of being served in the clear; HSTS is a per-chart `response-transformer` `KongPlugin` (`{fullname}-hsts`) injecting `Strict-Transport-Security`. The HSTS plugin is **combined** into the ingress's `konghq.com/plugins` list alongside the existing rate-limit-tier reference (comma-joined, not replacing it). ACME http-01 is unaffected — cert-manager's own solver Ingress serves the challenge path over http, separate from this route's https-only restriction (verify on first renewal). The aggregator half of Issue #10 is the nginx-edge HSTS in aggregator-dpg#609.

**Kong CRD gotcha:** Helm installs CRDs only from the top-level chart's `crds/` dir, only on first install — never from a subchart, never on upgrade. So `deploy_common_services` runs `apply_kong_crds` (`kubectl apply --server-side -f helm/common-services/crds/`) **before every helm upgrade**, or the controller crash-watches missing `KongClusterPlugin`/`KongPlugin` kinds. Don't remove that step thinking Helm handles it.

**Keycloak admin-console block (#1.7).** `keycloak.adminConsoleBlock.enabled` (chart default **off**; override via `global.adminConsoleBlock.enabled`) renders `helm/keycloak/charts/keycloak/templates/admin-console-block-ingress.yaml` — a more-specific Kong Ingress at `/auth/admin/master/console` with a `request-termination` (403) `KongPlugin`, mirroring the OTP-ratelimit ingress. It blocks the admin **console UI** from the public host while leaving `/auth/admin/realms/` (the admin **REST API**) reachable — aggregator-api's Keycloak admin client hits Keycloak through the public `KEYCLOAK_URL`, so blocking all of `/auth/admin` would break approval-time user provisioning. Reach the console via `kubectl port-forward` / VPN. Default off because it can only be validated by a live `install.sh dry_run`, not CI. A cleaner future step is to point aggregator-api's admin client at the in-cluster Keycloak service so all of `/auth/admin` can be blocked externally.

## cert-manager ACME workaround

`deploy_all_services` ends with `fix_acme_issuer_uri`, working around cert-manager v1.20.2 bug #7846: the controller never persists `status.acme.uri`, causing a re-registration loop that fails challenges with "No Key ID in JWS header". The function recovers the account id from a live challenge URL, patches the issuer status, and clears poisoned cert chains so they reissue. Teardown runs `cleanup_cert_manager_leftovers` because cert-manager CRDs + the ClusterIssuer carry a "keep" policy and survive `helm uninstall`, bricking the next install. If TLS certs are stuck (`kubectl get challenge -A`), this is the first thing to check.

## actingOrgId — a manual step between signals and aggregator

`aggregator` values' `global.signalstack.actingOrgId` only exists **after** the signals migrate-job seeds the `organization` table. After deploying signals, run `./get-signalstack-org-id.sh` (queries shared Postgres for the `network_service` org id), set it in the aggregator config, then deploy aggregator. The script handles **both backends**: it reads the host from the signals API's own ConfigMap, then execs into the in-cluster Postgres StatefulSet, or — when that host is RDS, where the Bitnami subchart is disabled and no such pod exists — into **`rds-relay`'s `psql` sidecar** (`default` ns; the relay template pins that namespace even though it ships in the common-services chart). Same shape either way, just a different pod. With no relay deployed it falls back to a throwaway pod on an EKS node, the route the `postgresBootstrap` Job uses. It keys off the API's configured host rather than which Postgres happens to be deployed, so a half-migrated cluster can't silently return a stale id from the old database. Skip it and aggregator login fails with `SIGNALSTACK_ORG_NOT_REGISTERED`. This is why the deploy order (signals before aggregator) is strict, not just conventional.

## Signals schema — applied from the api image (no vendored `schema.sql`)

The signals migrate-job does **not** vendor a `schema.sql` in this repo. A `migrate-ddl` initContainer runs the **api image itself** (`node apps/api/scripts/migrate.mjs`, i.e. `db:migrate:deploy`) as the app DB role: extension **preflight** → auto-baseline (legacy cutover) → one Drizzle `migrate()` over the committed `apps/api/drizzle/` ledger (declarative tables + the raw partitioned/geo tables as custom migrations). Because the schema ships inside the image and runs from that same image, the deployed schema always matches the running api build — **parity is automatic, nothing to keep in sync here**. A second `provision` container then upserts the **service apikeys** from the only SQL still vendored, `provision_service_users.sql`. Extensions are created upstream by `common-services` (`postgresBootstrap`) as the RDS master; the migrate step **asserts they exist and aborts loudly if not** (it never creates them — the app role is not a superuser).

### Service apikeys — adding one is a four-file change

`provision_service_users.sql` seeds one org + user + `apikey` row per integrating service, hashing the raw key as `base64url(sha256(raw))` to match better-auth's `defaultKeyHasher`. **Only the hash reaches the database** — the raw key lives solely in the generated `global-secrets.yaml` and in the caller's own config. Rotation is `UPDATE … WHERE user_id`, keyed per service user, so rotating one service never disturbs another.

| Service user | Key | Direction |
|---|---|---|
| `aggregator-dpg` | `AGGREGATOR_DPG_API_KEY` | aggregator → signals api |
| `signals-search-client` | `SIGNALS_SEARCH_API_KEY` | signals api → signals-search `/v1/relevance` |
| `raya-voice-bot` | `RAYA_VOICE_BOT_API_KEY` | raya voice bot → signals api |

Adding another means touching **four** places or it fails in a confusing way:
1. `charts/api/values.yaml` + umbrella `values.yaml` — declare the key under `secrets.data` (the api `secret.yaml` ranges over the whole map, so it's picked up automatically).
2. `migrate-env.yaml`'s **`$needed` allowlist** — the migrate-env Secret is a *deny-by-default* subset of `secrets.data`. Miss this and the key is simply absent from the Job's env.
3. `migrate-job.yaml` — the `:?missing` guard and a matching `psql -v`.
4. the SQL — a `set_config(...)` line **outside** the `DO $$…$$` block plus a `VALUES` row. psql's `:'var'` interpolation does not expand inside dollar-quoted strings, which is why the GUC hop exists.

**`RAYA_VOICE_BOT_API_KEY` is not the same credential as `secrets.voiceDpgSignalsSecret`.** Both belong to the same voice bot, but the latter is its `voice-dpg` Keycloak *client-credentials* secret (OIDC token exchange) while this is the *api-key* path. They are generated independently and rotate independently — do not "deduplicate" them.

**Operational note:** the `:?missing` guards make the migrate-job — and therefore the whole `signals` release — fail if a key is absent from the api Secret. So after pulling a change that adds a service apikey, run `bash install.sh apply_tf_output_file` to regenerate `global-secrets.yaml` **before** `deploy_signals`.

**Every one of these orgs is `type = 'network_service'`, and that collides with `actingOrgId`.** The org row is inserted with a hardcoded `network_service` type, and because `now()` is *transaction* time and the whole loop is one `DO $$…$$`, all of them share a byte-identical `created_at`. So `SELECT id FROM organization WHERE type='network_service' ORDER BY created_at LIMIT 1` — what `get-signalstack-org-id.sh` used to run, and what several docs told operators to run by hand — is a **tie with no deterministic winner**: a plain `UPDATE organization SET name = name` on any of those rows reorders the heap and flips the answer (verified). The script now filters on `slug` (`ORG_SLUG`, default `aggregator-dpg`, the org `actingOrgId` is defined as). **Adding a service apikey adds another `network_service` org, so never reintroduce a type-only lookup.**

## Consent config is ConfigMap-delivered (not baked into images)

Consent text/versions ship via ConfigMap so they change with a file edit + rollout, no rebuild. This repo is the downstream sync; canonical content lives in the unified schemas repo `Blue-Dots-Economy/bluedots-schemas` (per-network dirs at the repo root, e.g. `blue_dot/consent.json`, `blue_dot/upsdm/consent.json`), fetched at deploy time by `scripts/fetch-configs.sh`. The two charts deliver it differently — a real trap:

- **Signals** — source `helm/signals/charts/api/files/consent/<network>.json` (+ optional brand override `<network>.<brand>.json`), selected by `api.schemas.consentNetwork`/`consentBrand`. `schemas-configmap.yaml` renders `consent.json` next to the network schemas; the api reads it because `CONSENT_CONFIG_SOURCE: local` is pinned in values. It **deep-merges a brand file (partial) over the network default — so both files must be delivered**. A `checksum/schemas` annotation rolls pods on change; missing consent files **fail the template render**.
- **Aggregator** — source `helm/aggregator/files/consent/consent.json`, rendered into a `{release}-consent` ConfigMap, mounted single-file (subPath) into **both web and api** at `/app/config/<network>[/<brand>]/schemas/aggregator/consent.json`. Aggregator brand consent is a **FULL** document (not a partial). **subPath does NOT hot-update** → a consent change needs a rollout restart of web + api.

**Support-email placeholder:** consent JSON ships `__SUPPORT_EMAIL__` in its T&C/Privacy/Grievances copy; both renders substitute it at deploy time via Helm `replace` — signals from `.Values.schemas.consentSupportEmail`, aggregator from `.Values.global.consentSupportEmail`, each defaulting to `hello@bluedotseconomy.org`. **Change the value, never the consent content**, so a brand/network switch keeps the right contact.

## Email copy rides the signals consent ConfigMap (optional, per-key)

Per-network email wording (signals-dpg#540) ships the same way consent does and on the **same** `-schemas` ConfigMap, because the api resolves both from `dirname(NETWORK_CONFIG_LOCAL_FILE)`: `/app/schemas/messages.properties` and `/app/schemas/<brand>/messages.properties`. Canonical is `bluedots-schemas` `<network>/messages.properties` (+ `<network>/<brand>/`), fetched by `scripts/fetch-configs.sh signals` into the gitignored `helm/signals/charts/api/files/messages/`.

**It is optional, and that is the whole difference from consent.** The api bundles a complete set of email copy and merges these files **per key** (bundled defaults < `EMAIL_MESSAGES_PATH` < network < brand), so a network with no file — or a `--ref` predating the files — keeps the built-in wording. The fetch is therefore non-fatal (`try_fetch_optional`) and the render uses `with`, not `fail`. Consent has no in-app fallback, which is why it still fails hard.

Three traps:

- **It is keyed off `schemas.consentNetwork`/`consentBrand`, not its own value.** Deliberate: one served network must select consent *and* copy, or a pod could serve one network's consent beside another's emails. Setting `consentNetwork: ""` to fall back to image-baked consent drops the network email copy too.
- **`items` entries are conditional on the source file, not on the brand value.** An `items` entry naming a ConfigMap key that doesn't exist leaves the volume unmountable and the pod stuck in `ContainerCreating` — so the deployment template gates each entry on the same `Files.Get` the ConfigMap does.
- **The fetch clears the network's files before fetching.** Rendering keys off file *presence* (there is no values flag to switch copy off), so a leftover from an earlier deploy of a different brand would silently override copy on this one.

No `__SUPPORT_EMAIL__`-style substitution happens here — the copy's own `{{likeThis}}` placeholders are filled by the api at send time, so Helm passes the file through byte-for-byte. The `checksum/schemas` annotation already covers it, so a copy change rolls the api pods. Brand copy is **inert today**: no email send resolves a brand yet, so the file loads and validates at boot but changes no wording.

## `aggregator.config.yaml` is ConfigMap-delivered — fetched, not vendored

Same freshness model as consent and signals' network.json: `scripts/fetch-configs.sh aggregator` pulls it on every deploy into `helm/aggregator/files/network-config/aggregator.config.yaml` (gitignored), and `templates/network-config-configmap.yaml` renders it into `{release}-network-config`, subPath-mounted into api + worker **over the image-baked copy**. Net effect: update canonical, redeploy, config is live — **no image rebuild**.

**Rendered verbatim.** No placeholder rewriting, no field edits — whatever canonical says is what the pods get. The only runtime override is the network.json URL, supplied as `AGGREGATOR_NETWORK_SOURCE` (below), so the file never needs editing to repoint schemas.

**Its source is independent of the schemas repo.** Consent and network.json come from `bluedots-schemas`; `aggregator.config.yaml` lives in the `aggregator-dpg` `config/` tree. All four parts are configurable — flag > env > default:

| flag | env | default |
|---|---|---|
| `--config-repo` | `AGGREGATOR_CONFIG_REPO` | `Blue-Dots-Economy/aggregator-dpg` |
| `--config-ref` | `AGGREGATOR_CONFIG_REF` | `develop` (pin a tag/SHA for prod) |
| `--config-dir` | `AGGREGATOR_CONFIG_DIR` | `config` (empty = repo root) |
| `--config-file` | `AGGREGATOR_CONFIG_FILE` | `aggregator.config.yaml` |

`install.sh` passes all four from same-named variables, so repointing (e.g. to `bluedots-schemas` once it carries the file) needs no chart change. Only the `<network>[/<brand>]/` path segment is fixed — the app derives its own load path from `AGGREGATOR_NETWORK`/`AGGREGATOR_BRAND`, so the layout must match.

**Mounted into api + worker, not web.** Both run the loader (`apps/worker/src/services/network-config.ts` has five `getNetworkConfig()` call sites incl. `bulk-row-process.ts`). Web reads config through the api's `GET /v1/aggregator-config` and never touches disk.

**The mount path is derived, not chosen.** `resolveConfigPath()` computes `CONFIG_ROOT(/app/config)/<network>[/<brand>]/aggregator.config.yaml`; both deployment templates reproduce that derivation for `mountPath`. Brand is a path **segment**, not a suffix.

**Never set `AGGREGATOR_CONFIG_PATH`.** An explicit value wins over the derivation (`paths.ts:57`), so the mount — which lands at the derived path — would be ignored and the pod would read the baked file. The worker's ConfigMap used to set it while omitting the brand segment, which also split branded deploys: worker on the un-branded config, api (deriving) on the branded one. Commented out in both now.

**Single-file subPath, never a directory mount.** `/app/config/<network>/` also carries `brand.json` (read by the loader as a *sibling*), `keycloak.env`, `bulk-samples/*.csv` and the brand subtree, all from the image. A directory mount shadows every one of them, and a missing `brand.json` degrades *silently*. Consequence: `brand.json` design tokens (palette/typography/logo) still need an image rebuild; only the flat brand fields inside `aggregator.config.yaml` are ConfigMap-editable.

**Why `global.networkConfigDelivery` is a value and not a file-presence check.** `.Files` is chart-scoped, so a subchart cannot see whether the umbrella ConfigMap rendered — the mounts need a value to gate on. It doubles as the bypass for static renders with no fetched file, which is why `install.sh lint` and the CI helm job pass `--set global.networkConfigDelivery=false`. Setting it false in a real deploy falls back to the image-baked config.

**A change needs a pod restart, and helm won't do it.** subPath mounts don't hot-update, *and* api/worker cache the resolved config in a process-local singleton read once at boot. A config-only change also leaves the Deployment spec untouched, so `helm upgrade` rolls nothing — verified: editing the file leaves all three `checksum/config` annotations byte-identical. Those annotations hash each subchart's *own* configmap, and can't reach an umbrella template. Hence `deploy_aggregator` calls `restart_aggregator_config_consumers` (rollout restart + status wait on api, worker, web) after the upgrade. That function is **deliberately non-fatal**: `install.sh` runs under `set -euo pipefail` and the call is the last statement in `deploy_aggregator`, so propagating a slow-rollout failure would abort `deploy_all_services` and skip `fix_acme_issuer_uri`, breaking TLS as a side effect. It warns and returns 0; re-run standalone with `bash install.sh restart_aggregator_config_consumers`. It rolls pods on *every* deploy — the cost of having no usable checksum. Installing Reloader would let it be dropped.

### `AGGREGATOR_NETWORK_SOURCE` — the network.json URL

The aggregator **fetches network.json over HTTPS at boot** and holds it in memory; it is never a file on disk, unlike signals which mounts it at `/app/schemas/<net>.json`. So there is no path and no ConfigMap for it — the URL is the whole interface.

`global.networkSource` builds it, mirroring `fetch-configs.sh`'s signals derivation (`https://raw.githubusercontent.com/<repo>/<ref>/<network>/<file>`), and both api and worker ConfigMaps emit the result. `deploy_aggregator` passes `repo`/`ref` from `$SIGNALS_DPG_REPO`/`$SIGNALS_DPG_REF` — the same variables that drive the signals fetch — so **the two halves cannot resolve different schemas**. Pin the ref there, not in `global-values.yaml`. `global.networkSource.url` is a full-URL escape hatch for a mirror or internal host.

Two caveats. It **requires aggregator-dpg#513 in the deployed image**; until then nothing reads the var and it is silently inert (the YAML `source` is used). And because the fetch happens from the pod, api/worker need egress to that host, and the last-known-good cache (`dirname(configPath)/.cache`, overridable via `NETWORK_CONFIG_CACHE_DIR`) is per-pod ephemeral — a pod restart during a source outage fails boot.

Once #513 is deployed, canonical can drop `source:` from the YAML entirely (it becomes `.optional()` there), making the env var the single source of truth and turning a missing value into a loud `CONFIG_PARSE_FAILED` instead of a silent fallback. Note `fetch-configs.sh`'s `warn_if_moving_ref` does **not** cover this URL — it bypasses the fetch script.


## Org hierarchy flag

`global.orgHierarchyEnabled` (in `global-values.yaml`, default `true`) is emitted as `ORG_HIERARCHY_ENABLED` to the aggregator **web + api** pods via their ConfigMaps (`helm/aggregator/charts/{web,api}/templates/configmap.yaml`). There's no default in the aggregator chart's own `values.yaml`, so the global value must be present (it is) — set it identically for web and api or the two halves disagree.

## Shared Redis runs `noeviction`, not `allkeys-lru`

The single shared Redis (`common-services/values.yaml`, `redis.commonConfiguration`) backs **BullMQ job/queue state** and **Kong rate-limit counters** — not a disposable cache. Its `maxmemory-policy` is **`noeviction`** on purpose: `allkeys-lru` would silently evict live jobs and rate-limit counters under memory pressure (rate-limiting then fails *open*). With `noeviction` a full instance fails writes loudly instead. Two things follow: (1) every producer must bound its own keys — the Signals item-events stream is trimmed with `XADD MAXLEN` (`INGEST_STREAM_MAXLEN`); (2) `maxmemory` (512mb) must stay **below** the container memory limit in `helm/global-resources.yaml` (1Gi) so there's headroom before the pod OOMs. `replica.replicaCount` is `0` in the shared default because the 1-node dev cluster can't schedule a second pod — **prod deployment branches should set it ≥ 1** (noeviction makes a lost master more disruptive).

## Image pull secrets

Private images at `ghcr.io/blue-dots-economy/*` need a `ghcr-pull` secret per namespace. `create_namespaces_and_secrets` creates it in each via `rotate-ghcr-pull.sh` using `$GHCR_PAT` (a `read:packages` token). Some images also live under `vinodbbhorge/*` (Docker Hub). **Never commit a PAT.**

## Pod securityContexts + NetworkPolicies (#1.12)

**securityContexts.** The signals `api`/`ui`/`notification-service` subcharts already ship `podSecurityContext:`+`securityContext:` defaults wired via `toYaml` in their deployments. #1.12 extended the same per-subchart convention to the workloads that lacked it: aggregator `api`/`web`/`worker` and signals `search` (api+worker) get the node-app baseline (`runAsNonRoot`, `runAsUser: 1000`, `fsGroup: 1000`, drop ALL caps, `allowPrivilegeEscalation: false`); the TEI `search-embeddings` containers and the `keycloak` container get container-only hardening (drop ALL + no privilege escalation, **no forced uid** — TEI keeps its baked-cache user, keycloak keeps its pod-level `fsGroup: 0`). Override per-service in the subchart/umbrella values if an image needs root (cf. the signals `ui` nginx exception).

**NetworkPolicies.** `networkPolicy.enabled` (umbrella values for both `signals` and `aggregator`; **default OFF**) renders `templates/networkpolicy.yaml` — an **Ingress-only** policy selecting all pods in the namespace, allowing connections only from the same namespace + `networkPolicy.allowedFromNamespaces` (matched on the built-in `kubernetes.io/metadata.name` label). Egress is intentionally unrestricted (keeps cross-namespace DB/Redis/Keycloak/DNS working without a second policy). It's default-off and opt-in because it can only be validated by a live `install.sh dry_run` (bluedots CI runs no Helm validation) — **validate `allowedFromNamespaces` against your topology before enabling** (e.g. `aggregator` must stay listed for signals, since aggregator-dpg calls the signals API; `common-services` must stay listed everywhere, as Kong proxies public traffic from there). Mirrors the existing `common-services` DB-ingress policy pattern.

## Aggregator mandatory-secret guard

`helm/aggregator/templates/secrets.yaml` renders the mandatory credentials (postgres/redis passwords, Keycloak admin + client secrets, `APPROVAL_TOKEN_SECRET`, `SESSION_KEY`) through the `aggregator.requireSecret` helper, which **fails the render** if a value is empty or still a `change-me` placeholder — so the platform can't deploy on a well-known default. Real deploys pass real values from the generated `global-secrets.yaml` via `-f`, so the guard is transparent there. It fires on **any** render, though — including `helm lint`/`helm template` with chart defaults — so static checks that have no real creds skip the secret block with `--set global.existingSecret=<placeholder>` (this is what `install.sh lint` does, and what the CI `helm` job passes for the aggregator chart). Setting `global.existingSecret` to a real pre-created Secret also bypasses the guard by design.
