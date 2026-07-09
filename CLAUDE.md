# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**bluedots-automation** is an infrastructure-as-code and deployment system for the Blue Dots Economy platform. It does two things:

1. **Provisions AWS EKS infrastructure** using OpenTofu + Terragrunt (`opentofu/aws/`).
2. **Deploys the application stack** to Kubernetes using Helm (`helm/`).

Both are driven by a **single `install.sh`** that lives in the per-environment
directory (`opentofu/aws/<env>/install.sh`). See [DEPLOYMENT.md](DEPLOYMENT.md)
for the end-to-end runbook.

> ⚠️ **There is no Makefile.** Older docs (and this file's previous version)
> referenced `make install` / `make platform-install`. Those targets are gone —
> `install.sh` is the only entrypoint. If you see `make ...` in stray chart
> READMEs or comments, treat it as stale. **install.sh and DEPLOYMENT.md are the
> source of truth**; README.md is kept current alongside this file.

---

## ⚠️ CRITICAL: Directory vs Chart vs Release vs Namespace

Release name and namespace now **match the directory name**. Only the Helm
**chart name** (the `name:` in `Chart.yaml`) differs — and it differs for every
app chart. So when `helm list`, logs, or templates say **`dpg`**, that's the
**Signals** chart in `helm/signals/`.

| Directory              | Chart `name`     | Release           | Namespace         | Purpose |
|------------------------|------------------|-------------------|-------------------|---------|
| `helm/monitoring/`     | `monitoring`     | `monitoring`      | `monitoring`      | Prometheus + Alertmanager + Loki + Alloy + Jaeger + Grafana |
| `helm/common-services/`| `platform`       | `common-services` | `common-services` | Cluster-wide: **Kong** ingress, cert-manager, shared Postgres, Redis, metrics-server |
| `helm/signals/`        | `dpg`            | `signals`         | `signals`         | Signals stack (api, ui, notification-service, match-score) |
| `helm/aggregator/`     | `aggregator-dpg` | `aggregator`      | `aggregator`      | Aggregator portal (web/BFF, api, worker, keycloak) |

Namespaces / releases / values-file paths are all overridable via env vars
(`CS_NS`, `SIGNALS_NS`, `CS_REL`, `GLOBAL_VALUES`, …) — see the function
reference in DEPLOYMENT.md.

---

## Deploy Order (STRICT)

`deploy_all_services` runs charts in this order; the **common-services → signals
→ aggregator** dependency order is mandatory:

1. **`monitoring`** — installed first so metrics/alerts are live from the start (its `kube-prometheus-stack` also ships the ServiceMonitor/PodMonitor/PrometheusRule CRDs others rely on). Functionally optional but deployed first by default.
2. **`common-services`** — owns the **Kong** ingress controller, cert-manager + `letsencrypt-prod` ClusterIssuer, and shared Postgres/Redis. Without it, other Ingresses sit Pending and ACME challenges fail.
3. **`signals`** — connects to the shared DBs in `common-services`.
4. **`aggregator`** — same shared DBs; longest rollout (Keycloak init Job runs after Postgres is Ready).

Each `deploy_*` runs `helm upgrade --install … --wait`, so it blocks on its own
pods but does **not** verify cross-namespace deps — confirm common-services
Postgres/Redis are Ready before deploying signals/aggregator.

---

## Common Commands

All commands run from the **environment directory** (`opentofu/aws/<env>/`).
On trunk branches only `template/` exists — copy it to create an env:
`cp -R opentofu/aws/template opentofu/aws/dev && cd opentofu/aws/dev`.
(Per-deployment branches carry their own `opentofu/aws/<env>/` directory.)

### Infrastructure (OpenTofu/Terragrunt)

```bash
# Full infra bootstrap (no args): create_tf_backend → create_tf_resources → apply_gp3_default_sc
bash install.sh

# Individual steps
bash install.sh create_tf_backend       # create S3 tfstate bucket, write tf.sh
bash install.sh create_tf_resources     # source tf.sh + terragrunt run --all apply + write kubeconfig
bash install.sh apply_gp3_default_sc     # make gp3 the default StorageClass (demote gp2)
bash install.sh destroy_tf_resources     # terragrunt run --all destroy

# Plan / apply a single tofu module (network|eks|iam|storage|random_passwords|rds|output-file)
bash install.sh plan_tf_eks
bash install.sh apply_tf_output_file     # regenerate just the values files
```

### Application Deployment (Helm)

```bash
export GHCR_PAT=ghp_xxx                   # read:packages token; needed for image pulls

# Full stack in order
bash install.sh deploy_all_services       # preflight → ns+secrets → monitoring → common-services → signals → aggregator → fix_acme_issuer_uri

# Individual steps
bash install.sh create_namespaces_and_secrets   # create namespaces + ghcr-pull secret in each
bash install.sh deploy_monitoring
bash install.sh deploy_common_services    # applies gp3 + Kong CRDs first, then helm --wait
bash install.sh deploy_signals
bash install.sh deploy_aggregator

# Teardown (reverse order)
bash install.sh cleanup_all_services      # DESTRUCTIVE: deletes namespaces incl. Postgres/Redis PVCs
bash install.sh destroy_aggregator        # individual

# Static checks
bash install.sh lint        # helm lint all 4 charts (no cluster needed)
bash install.sh dry_run     # helm --dry-run all 4 against current cluster (runs preflight first)
bash install.sh preflight   # verify helm + kubectl + cluster + generated values files exist
```

Chain functions in one call: `bash install.sh lint dry_run`.

---

## Values-File Architecture (how Helm config is assembled)

Config is **never injected into chart `values.yaml`**. Each `helm upgrade` layers
files via repeated `-f` (later wins). Keys sit at **root level keyed by chart**
(e.g. `api:`, `ui:`, `aggregator-api:`, `alerting:`), so a single `-f` feeds Helm
directly — no `yq` slicing (which is why `preflight` no longer needs `yq`).

| File | Source | Committed? | Holds |
|------|--------|-----------|-------|
| chart `values.yaml` | in repo | yes | chart defaults / structure |
| `helm/global-resources.yaml` | in repo, **shared across all envs** | yes | replica counts, HPA, PDB, container resources |
| `<env>/global-images.yaml` | in repo, **per-env** | yes | image `repository` / `tag` / `pullPolicy` |
| `<env>/global-values.yaml` | in repo, **per-env, user-edited** | yes | non-secret config: hosts, network/brand, SMTP, MSG91, DB sizing, app config |
| `<env>/global-credentials.yaml` | **generated** by `output-file` module | **no** (`.gitignore`) | all secrets (PG/Redis/auth passwords) |
| `<env>/global-cloud-values.yaml` | **generated** by `output-file` module | **no** (`.gitignore`) | cloud outputs + computed config: S3 bucket/region, IRSA role ARN, computed hosts/origins, **RDS Postgres host** (when provisioned) |

`preflight` fails if `global-credentials.yaml` / `global-cloud-values.yaml` are
missing → run `terragrunt run --all apply` (or `bash install.sh
create_tf_resources`) first to generate them. After editing config that feeds the
generated files, regenerate only them with `bash install.sh apply_tf_output_file`.

### Editing `global-values.yaml`: anchors only

`global-values.yaml` is structured as a top **"Environment inputs"** block of YAML
anchors (`_building_block`, `_environment`, `_signals_public_hosts`,
`_aggregator_host`, `_grafana_host`, `_network`, `_brand`, SMTP, MSG91, alert
emails, EKS sizing, RDS sizing, …). Everything under `global:` *references* those
anchors. **Edit the anchor definitions at the top only** — don't hunt through the
body. `_network` is the upstream network identity; `_brand` is a UI/config skin
over it (e.g. `upsdm` over `blue_dot`) and does not change the network.

---

## Ingress: Kong (not nginx)

`common-services` vendors both `ingress-nginx` and `kong` subcharts, but the
committed default is **Kong** (`kong.enabled: true`, `ingress-nginx.enabled:
false`). Kong (DB-less) is the sole controller and `kong` is the cluster-default
IngressClass; all app Ingress objects set `ingressClassName: kong`. Rate limiting
is enforced by `KongClusterPlugin` tiers (`rl-auth`/`rl-api`/`rl-public`) defined
in `helm/common-services/values.yaml`, attached per route via the
`konghq.com/plugins` annotation, with counters in the shared Redis
(`policy: redis`).

**Kong CRD gotcha:** Helm installs CRDs only from the top-level chart's `crds/`
dir and only on first install — never from a subchart, never on upgrade. So
`deploy_common_services` runs `apply_kong_crds` (`kubectl apply --server-side -f
helm/common-services/crds/`) before every helm upgrade, or the controller
crash-watches missing `KongClusterPlugin`/`KongPlugin` kinds.

## cert-manager ACME workaround

`deploy_all_services` ends with `fix_acme_issuer_uri`, which works around
cert-manager v1.20.2 bug [#7846](https://github.com/cert-manager/cert-manager/issues/7846):
the controller never persists `status.acme.uri`, causing a re-registration loop
that fails challenges with "No Key ID in JWS header". The function recovers the
account id from a live challenge URL, patches the issuer status, and clears
poisoned cert chains so they reissue. Teardown (`destroy_common_services`) runs
`cleanup_cert_manager_leftovers` because cert-manager CRDs and the ClusterIssuer
carry a "keep" policy and survive `helm uninstall`, bricking the next install.

## actingOrgId (post-signals manual step)

`aggregator-values.yaml` / `global.signalstack.actingOrgId` only exists after the
signals migrate-job seeds the `organization` table. After deploying signals, run
`./get-signalstack-org-id.sh` (queries the shared Postgres for the
`network_service` org id), set it in the aggregator config, then deploy
aggregator. Without it, aggregator login fails with
`SIGNALSTACK_ORG_NOT_REGISTERED`.

## Consent config (ConfigMap-delivered)

Consent text/versions are shipped via **ConfigMap**, not baked into images, so
they change with a file edit + rollout (no rebuild). This repo is the downstream
sync; canonical consent content lives in the app repos.

- **Signals** — source files `helm/signals/charts/api/files/consent/<network>.json`
  and optional brand override `<network>.<brand>.json`. Selected by
  `api.schemas.consentNetwork` / `api.schemas.consentBrand` (set in
  `global-values.yaml`). `schemas-configmap.yaml` renders `consent.json` (and, for a
  brand, a `<brand>-consent.json` key remapped via the deployment volume `items` to
  the nested path `/app/schemas/<brand>/consent.json`) next to the network schemas.
  The api reads it because `CONSENT_CONFIG_SOURCE: local` is set **explicitly** in
  values (the app default today, pinned so intent survives a default change). It
  reads `consent.json` from `dirname(NETWORK_CONFIG_LOCAL_FILE)` and deep-merges a
  brand file (partial) over the network default — so **both files must be
  delivered**. Consent is cached in-process; the api deployment carries a
  `checksum/schemas` annotation that rolls pods when consent/network files change.
  Missing consent files `fail` the template render.
  > Search subchart reuses this ConfigMap and dir-scans `/app/schemas` for network
  > `*.json`; `consent.json` has no `id` so it's keyed under `undefined` and never
  > looked up (harmless), and the `<brand>/` subdir is skipped by its `.json` filter.
- **Aggregator** — source file `helm/aggregator/files/consent/consent.json`, rendered
  into a `{release}-consent` ConfigMap (`helm/aggregator/templates/consent-configmap.yaml`)
  and mounted single-file (subPath) into **both web and api** pods at
  `/app/config/<network>[/<brand>]/schemas/aggregator/consent.json`. Aggregator brand
  consent is a **FULL** document (not a partial), and each deploy serves one
  network+brand, so the single mounted file is complete. subPath does **not**
  hot-update → a consent change needs a rollout restart of web + api.

The Signals migrate Job builds `consent_record` (consent ledger) from the bundled
`helm/signals/charts/api/files/schema.sql`; refresh that bundle when the upstream
Signals-DPG schema changes. `consent_text` is intentionally NOT in the deployed
`network.json` — consent is served separately, so its absence is expected.

## Org hierarchy

`global.orgHierarchyEnabled` (in `global-values.yaml`, default `true`) is emitted
as `ORG_HIERARCHY_ENABLED` to the **aggregator web + api** pods via their ConfigMaps
(`helm/aggregator/charts/{web,api}/templates/configmap.yaml`). No default in the
aggregator chart's own `values.yaml`, so the global value must be present (it is, in
`global-values.yaml`).

## develop-PR docs & release-notes gate

PRs into **`develop`** run `.github/workflows/develop-pr-gate.yml`, which calls the
composite action `.github/actions/pr-gate/` (`action.yml` → `check.mjs`). It
**fails closed** unless the PR has both a non-empty `## Release Notes` section in
the body AND a change to `README.md`/`CLAUDE.md` — each waivable via the
`no-release-notes` / `no-doc-update` label. Pure logic lives in `gate.mjs`
(no deps, no IO); `check.mjs` pulls the PR body/labels/files (via `gh api`, with a
`PR_FILES` escape hatch) and calls `evaluate()`. Unit tests `gate.test.mjs` run via
`node --test` in the `pr-gate-tests` workflow (triggered on changes under
`.github/actions/pr-gate/**`). PR body scaffolding: `.github/PULL_REQUEST_TEMPLATE.md`.
The gate only blocks merges once a repo/org ruleset requires the check on `develop`.

---

## Architecture Layers

### OpenTofu/Terragrunt Structure

Located at `opentofu/aws/<env>/` (e.g. `template/` reference, or a per-deployment
`dev/`):

- **`global-values.yaml`** — the *only* file you edit (anchors at the top). Controls cluster size, region, instance types, node counts, IRSA subjects, hosts, RDS sizing.
- **`root.hcl`** — Terragrunt backend/provider generation (from `global-values.yaml`).
- **`tf.sh`** — written by `create_tf_backend`; exports AWS region + tfstate bucket. `create_tf_resources` sources it first.
- **Modules** (one dir per module: `network/`, `eks/`, `iam/`, `storage/`, `random_passwords/`, `rds/`, `output-file/`):
  - Each has a `terragrunt.hcl` including shared logic from `_common/`.
  - All read from `global-values.yaml`.
  - Provision order: network → EKS → IAM → storage → random_passwords → rds → output-file.

**Managed Postgres (`rds` module)** is opt-in infra; `global-values.yaml` carries
`rds_*` sizing. Its SG allows `5432` only from the EKS cluster SG, and it shares
the master password with the `random_passwords`-generated secret. **Pointing the
charts at RDS is automated:** the `rds` module's `db_address` flows (via
`_common/output-file.hcl` → `postgres_host`) into the `output-file` module, which
— *only when the endpoint is non-empty* — emits `global.dataPlatform.postgresHost`,
`api.postgres.host`, and `search.postgres.host` into `global-cloud-values.yaml`.
Layered after `global-values.yaml` via `-f`, the RDS endpoint overrides the
in-cluster default for signals + aggregator; with no RDS endpoint the overrides
are omitted. (App DB roles/databases must still exist on the RDS instance.)

### Helm Stack Structure

Four umbrella charts in `helm/`:

- **`helm/monitoring/`** (chart `monitoring`): subcharts `kube-prometheus-stack` (Prometheus Operator, Prometheus, Alertmanager, node-exporter, kube-state-metrics — *and* the monitoring CRDs), `loki`, `alloy` (DaemonSet log shipper, replaces Promtail), `jaeger`, Grafana. Grafana host is `_grafana_host`.
- **`helm/common-services/`** (chart `platform`): Kong ingress, cert-manager + `letsencrypt-prod` issuer, shared Postgres (in-cluster Postgres is disabled by default when RDS is used), Redis, metrics-server. Passwords generated on first install into `data-postgres` / `data-redis` Secrets in `common-services`.
- **`helm/signals/`** (chart `dpg`): api, ui, notification-service, match-score. Connects to shared DBs.
- **`helm/aggregator/`** (chart `aggregator-dpg`): web (BFF), api, worker, keycloak. Vendored `ingress-nginx`/`cert-manager` subcharts are disabled (`platform` owns them). Keycloak init Job depends on Postgres readiness.

---

## Image Pull Secrets

Private images at `ghcr.io/blue-dots-economy/*` require a `ghcr-pull` secret per
namespace. `create_namespaces_and_secrets` creates it in each namespace via
`rotate-ghcr-pull.sh` using `$GHCR_PAT` (a `read:packages` token). Some images
also live under `vinodbbhorge/*` (Docker Hub). **Never commit a PAT.**

---

## State & Secrets

- **Infrastructure state**: S3 bucket (encrypted, versioned, private). Never committed; `.terraform/`, `*.tfstate`, `*.tfvars`, generated `tf.sh` / `global-cloud-values.yaml` / `global-credentials.yaml` are gitignored.
- **App secrets**: generated by the `random_passwords` + `output-file` tofu modules into the gitignored `global-credentials.yaml`, and stored at runtime in Kubernetes Secrets. SMTP/MSG91/maps keys are set as anchors in `global-values.yaml`.

---

## Branch Strategy

Two kinds of branches: **trunk** branches that integrate work, and
**per-deployment** branches that hold one deployment's config.

### Trunk (promotion chain)

Work flows up: `<your-feature-branch>` → `feature` → `develop` → `main`.

- **`main`** — the canonical/standard branch. **Cut new deployment branches from here.**
- **`develop`** — pre-release integration.
- **`feature`** — collects in-progress work before promotion; usually the *newest* trunk branch, so check it for the latest unreleased changes.

```bash
git switch main && git pull origin main
```

### Per-deployment branches

Each live deployment has its **own long-lived branch** (branched from trunk),
carrying only that deployment's config — network JSON schemas, image tags,
public hostnames, and its own `opentofu/aws/<env>/` directory. **Never deploy a
customer environment from `main`; use its branch.**

| Branch | Env | Notes |
|--------|-----|-------|
| `blue-dots-dev` | dev | |
| `orange-dots-dev` | dev | |
| `orange-dot-prod` | prod | carries Kong ingress (`kong-nginx-impl`) |
| `purple-dots-prod` | prod | **legacy** — still on the old `helmcharts/` layout |

---

## Prerequisites & Tools

| Tool | Purpose | Min Version |
|------|---------|-------------|
| `aws` CLI | credentials, S3 tfstate | v2 |
| `tofu` (OpenTofu) | provisioning via terragrunt | 1.6+ |
| `terragrunt` | OpenTofu orchestration | 0.90+ |
| `kubectl` | cluster communication | ≥ 1.24 (matches EKS) |
| `helm` | Kubernetes deployments | v3.12+ |
| `bash` | runs `install.sh` | 4.x+ |

> `yq` is **no longer required** — per-chart value slicing was removed; the tofu
> `output-file` module emits root-level files directly. (README's prereq table is
> stale on this point.)

Also required: AWS creds with VPC/EKS/IAM/S3 rights; a GHCR `read:packages` token
(`GHCR_PAT`); DNS control to point public hosts at the **Kong proxy**
LoadBalancer (`kubectl -n common-services get svc common-services-kong-proxy`)
once it exists.

---

## Inspect & Debug

```bash
# Cluster state
kubectl cluster-info
kubectl get sc                                  # gp3 (default); gp2 not default
kubectl -n common-services get pods,svc,pvc
kubectl -n signals get pods,svc,ingress
kubectl -n aggregator get pods,svc,ingress
kubectl -n monitoring get pods

# Helm releases
helm list -A                                    # monitoring, common-services, signals, aggregator

# TLS issuance
kubectl get clusterissuer letsencrypt-prod
kubectl get certificate -A                      # READY=True once ACME completes
kubectl get challenge -A                        # if certs stuck, see fix_acme_issuer_uri

# Generated Postgres password
kubectl -n common-services get secret data-postgres -o yaml

# Logs / port-forward
kubectl -n signals logs -f deploy/signals-api
kubectl -n aggregator logs -f deploy/aggregator-web
```

See [DEPLOYMENT.md → Troubleshooting](DEPLOYMENT.md) for symptom→fix table.

---

## New Environment

1. Copy `opentofu/aws/template/` to `opentofu/aws/<env>/` (the env name is the directory basename, read by `install.sh`).
2. Edit `opentofu/aws/<env>/global-values.yaml` (anchors at the top).
3. `cd opentofu/aws/<env> && bash install.sh` (infra), then `bash install.sh deploy_all_services` (apps).

For a full **new-instance / new-network** launch (network.json, brand assets,
terms & policies, domains, auth channels, and all per-instance config as a
single end-to-end checklist), follow
[docs/instance-setup.md](docs/instance-setup.md).

---

## Files to Know

- `DEPLOYMENT.md` — authoritative end-to-end runbook + `install.sh` function reference + troubleshooting.
- `docs/instance-setup.md` — per-instance checklist for launching a new environment / network / brand (layers on DEPLOYMENT.md).
- `opentofu/aws/<env>/install.sh` — single entrypoint for infra **and** Helm deploy (function dispatcher).
- `opentofu/aws/<env>/global-values.yaml` — single source of truth for cluster + app config (edit anchors only).
- `helm/global-resources.yaml` — shared replica/HPA/PDB/resource overrides across all envs.
- `opentofu/aws/_common/*.hcl` — shared Terragrunt/OpenTofu logic.
- `opentofu/aws/modules/output-file/` — generates `global-credentials.yaml` + `global-cloud-values.yaml`.
- `helm/signals/charts/api/files/consent/` + `helm/aggregator/files/consent/` — consent JSON delivered via ConfigMap.
- `.github/actions/pr-gate/` + `.github/workflows/develop-pr-gate.yml` — docs/release-notes gate for develop PRs; `.github/PULL_REQUEST_TEMPLATE.md` is the PR body scaffold.
- `.gitignore` — ignores state, secrets, generated values, `.terraform/`, `*.tfstate`, `*.tfvars`, and local-only `docs/`.
- `README.md` / `helm/README.md` / per-chart `helm/*/README.md` — overview + per-chart standalone deploy instructions.
```
