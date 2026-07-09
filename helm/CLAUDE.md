# CLAUDE.md — helm (application deployment)

Guidance for the Helm half of the repo. Read the root `CLAUDE.md` first (the critical directory/chart/release/namespace table, the strict deploy order, the values-file architecture). Per-chart `README.md` files (`helm/README.md`, `helm/monitoring/README.md`, etc.) cover standalone-deploy detail; this file covers the Claude-specific gotchas that span or aren't obvious from the charts.

## The four umbrella charts

- **`monitoring/`** (chart `monitoring`) — `kube-prometheus-stack` (Prometheus Operator + Prometheus + Alertmanager + node-exporter + kube-state-metrics, **and the monitoring CRDs** others depend on), `loki`, `alloy` (DaemonSet log shipper, replaced Promtail), `jaeger`, Grafana (`_grafana_host`). The stock kube-prometheus ruleset is **disabled** (`defaultRules.create: false`) — alerting is a curated `additionalPrometheusRulesMap`. See `helm/monitoring/README.md`.
- **`common-services/`** (chart `platform`) — Kong ingress, cert-manager + `letsencrypt-prod` issuer, shared Postgres (disabled by default when RDS is used), Redis, metrics-server. Passwords generated on first install into `data-postgres`/`data-redis` Secrets in the `common-services` namespace.
- **`signals/`** (chart `dpg`) — api, ui, notification-service, match-score. Connects to the shared DBs in `common-services`.
- **`aggregator/`** (chart `aggregator-dpg`) — web (BFF), api, worker, keycloak. Vendored `ingress-nginx`/`cert-manager` subcharts are **disabled** (`platform` owns them). Keycloak init Job depends on Postgres readiness → longest rollout.

Resource requests/limits (Kong `replicaCount: 2`, cert-manager, Redis, `postgresBootstrap`, metrics-server, app replicas/HPA/PDB) live in the shared `helm/global-resources.yaml`, not per-chart values.

## Ingress is Kong, not nginx

`common-services` vendors both `ingress-nginx` and `kong` subcharts, but the committed default is **Kong** (`kong.enabled: true`, `ingress-nginx.enabled: false`). Kong (DB-less) is the sole controller and the cluster-default IngressClass; every app Ingress sets `ingressClassName: kong`. Rate limiting is `KongClusterPlugin` tiers (`rl-auth`/`rl-api`/`rl-public`) in `helm/common-services/values.yaml`, attached per route via the `konghq.com/plugins` annotation, counters in the shared Redis (`policy: redis`). DNS points public hosts at the Kong proxy LB: `kubectl -n common-services get svc common-services-kong-proxy`.

**Kong CRD gotcha:** Helm installs CRDs only from the top-level chart's `crds/` dir, only on first install — never from a subchart, never on upgrade. So `deploy_common_services` runs `apply_kong_crds` (`kubectl apply --server-side -f helm/common-services/crds/`) **before every helm upgrade**, or the controller crash-watches missing `KongClusterPlugin`/`KongPlugin` kinds. Don't remove that step thinking Helm handles it.

## cert-manager ACME workaround

`deploy_all_services` ends with `fix_acme_issuer_uri`, working around cert-manager v1.20.2 bug #7846: the controller never persists `status.acme.uri`, causing a re-registration loop that fails challenges with "No Key ID in JWS header". The function recovers the account id from a live challenge URL, patches the issuer status, and clears poisoned cert chains so they reissue. Teardown runs `cleanup_cert_manager_leftovers` because cert-manager CRDs + the ClusterIssuer carry a "keep" policy and survive `helm uninstall`, bricking the next install. If TLS certs are stuck (`kubectl get challenge -A`), this is the first thing to check.

## actingOrgId — a manual step between signals and aggregator

`aggregator` values' `global.signalstack.actingOrgId` only exists **after** the signals migrate-job seeds the `organization` table. After deploying signals, run `./get-signalstack-org-id.sh` (queries shared Postgres for the `network_service` org id), set it in the aggregator config, then deploy aggregator. Skip it and aggregator login fails with `SIGNALSTACK_ORG_NOT_REGISTERED`. This is why the deploy order (signals before aggregator) is strict, not just conventional.

## Signals schema — applied from the api image (no vendored `schema.sql`)

The signals migrate-job does **not** vendor a `schema.sql` in this repo. A `migrate-ddl` initContainer runs the **api image itself** (`node apps/api/scripts/migrate.mjs`, i.e. `db:migrate:deploy`) as the app DB role, applying, in order: extensions → Drizzle migrations (better-auth + metrics/pii/consent tables) → the raw partitioned item/action/event DDL → version migrations. Because the DDL ships inside the image and runs from that same image, the deployed schema always matches the running api build — **parity is automatic, nothing to keep in sync here**. A second `provision` container then upserts the integrating-DPG (aggregator-dpg) apikey from the only SQL still vendored, `provision_service_users.sql`. Extensions themselves are created upstream by `common-services` (`postgresBootstrap`) as the RDS master; the migrate step's `CREATE EXTENSION IF NOT EXISTS` is a no-op in deploy.

## Consent config is ConfigMap-delivered (not baked into images)

Consent text/versions ship via ConfigMap so they change with a file edit + rollout, no rebuild. This repo is the downstream sync; canonical content lives in the app repos. The two charts deliver it differently — a real trap:

- **Signals** — source `helm/signals/charts/api/files/consent/<network>.json` (+ optional brand override `<network>.<brand>.json`), selected by `api.schemas.consentNetwork`/`consentBrand`. `schemas-configmap.yaml` renders `consent.json` next to the network schemas; the api reads it because `CONSENT_CONFIG_SOURCE: local` is pinned in values. It **deep-merges a brand file (partial) over the network default — so both files must be delivered**. A `checksum/schemas` annotation rolls pods on change; missing consent files **fail the template render**.
- **Aggregator** — source `helm/aggregator/files/consent/consent.json`, rendered into a `{release}-consent` ConfigMap, mounted single-file (subPath) into **both web and api** at `/app/config/<network>[/<brand>]/schemas/aggregator/consent.json`. Aggregator brand consent is a **FULL** document (not a partial). **subPath does NOT hot-update** → a consent change needs a rollout restart of web + api.

**Support-email placeholder:** consent JSON ships `__SUPPORT_EMAIL__` in its T&C/Privacy/Grievances copy; both renders substitute it at deploy time via Helm `replace` — signals from `.Values.schemas.consentSupportEmail`, aggregator from `.Values.global.consentSupportEmail`, each defaulting to `hello@bluedotseconomy.org`. **Change the value, never the consent content**, so a brand/network switch keeps the right contact.

## Org hierarchy flag

`global.orgHierarchyEnabled` (in `global-values.yaml`, default `true`) is emitted as `ORG_HIERARCHY_ENABLED` to the aggregator **web + api** pods via their ConfigMaps (`helm/aggregator/charts/{web,api}/templates/configmap.yaml`). There's no default in the aggregator chart's own `values.yaml`, so the global value must be present (it is) — set it identically for web and api or the two halves disagree.

## Image pull secrets

Private images at `ghcr.io/blue-dots-economy/*` need a `ghcr-pull` secret per namespace. `create_namespaces_and_secrets` creates it in each via `rotate-ghcr-pull.sh` using `$GHCR_PAT` (a `read:packages` token). Some images also live under `vinodbbhorge/*` (Docker Hub). **Never commit a PAT.**
