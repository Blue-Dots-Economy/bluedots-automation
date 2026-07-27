# Helm — Blue Dots Economy

Four umbrella charts that together stand up the full Blue Dots Economy stack on
a Kubernetes cluster (typically EKS, provisioned via `opentofu/`).

Install in this strict order:

| # | Directory         | Chart `name`     | Release           | Namespace         | What it deploys                                                  |
|---|-------------------|------------------|-------------------|-------------------|------------------------------------------------------------------|
| 1 | `monitoring`      | `monitoring`     | `monitoring`      | `monitoring`      | kube-prometheus-stack (Prometheus, Alertmanager) + Loki + Alloy + Jaeger + Grafana |
| 2 | `common-services` | `platform`       | `common-services` | `common-services` | **Kong** ingress, cert-manager, `letsencrypt-prod` ClusterIssuer, shared Postgres + Redis, metrics-server |
| 3 | `signals`         | `dpg`            | `signals`         | `signals`         | Signals monorepo: api, ui, notification-service, match-score     |
| 4 | `aggregator`      | `aggregator-dpg` | `aggregator`      | `aggregator`      | Aggregator portal: web (BFF), api, worker, keycloak              |

> The directory, chart `name`, release, and namespace are **not** the same. Only
> the chart `name` differs from the directory now; release + namespace match the
> directory. So `helm list` showing `dpg` means **Signals** (`helm/signals/`).

Everything is driven by **`install.sh`** inside each environment directory
(`opentofu/aws/<env>/install.sh`) — one script for both cloud bootstrap and helm
deploy. **There is no Makefile.** Monitoring is functionally optional but
deployed first by default (its `kube-prometheus-stack` also ships the
ServiceMonitor/PodMonitor/PrometheusRule CRDs the rest of the stack uses).

## Where the config comes from

Config is **never hand-edited into a chart `values.yaml`**. Each `helm upgrade`
layers files via repeated `-f` (last wins), each keyed at the YAML **root** level
by chart/component so helm reads it directly — no slicing, no `yq`:

| File | Source | Committed? | Holds |
|------|--------|-----------|-------|
| `helm/global-resources.yaml`     | in repo, shared across envs | yes | replicas, HPA, PDB, container resources |
| `<env>/global-images.yaml`       | in repo, per-env            | yes | image `repository` / `tag` / `pullPolicy` |
| `<env>/global-values.yaml`       | in repo, **you edit**       | yes | non-secret config (hosts, network/brand, some SMTP/MSG91/maps fields, RDS sizing, app config) — edit the **anchors at the top** |
| `<env>/global-secrets.yaml`  | **generated** by tofu (`output-file`) | **no** (gitignored) | all secrets |
| `<env>/global-cloud-values.yaml` | **generated** by tofu (`output-file`) | **no** (gitignored) | cloud outputs + computed config (S3, IRSA ARN, RDS Postgres host, hostBindings) |

The two generated files are templated by the `output-file` opentofu module
(`opentofu/aws/modules/output-file/*.tfpl`) from `network`, `eks`, `iam`,
`storage`, `random_passwords`, and `rds` outputs. They are **shared by all
charts** (keyed by chart-component), not one file per chart. Shared secrets (e.g.
the redis password, used by multiple charts) are templated from the same tofu
variable, so they can never drift.

A few fields (aggregator `secrets.smtpPassword`/`msg91AuthKey`, signals
`notification-service.secrets.data.GMAIL_PASS`/`MSG91_AUTH_KEY`/`MSG91_TEMPLATE_ID`,
`api.secrets.data.GOOGLE_GEOCODING_API_KEY`) are the exception: the `.tfpl`
bakes in a literal `UPDATE_THIS_VALUE` instead of a tofu variable, so you edit
the real value directly in the generated `global-secrets.yaml` — no
`global-values.yaml` edit or re-apply needed. Re-running
`apply_tf_output_file` regenerates the file and resets these back to the
placeholder, so do it after your last regen for the env.

```yaml
# global-secrets.yaml (secrets — root keys by component)
credentials:                       # common-services
  postgresAdminPassword: <generated>
  aggregatorPassword: <generated>
  dpgPassword: <generated>
  redisPassword: <generated>
prometheus: { grafana: { ... } }   # monitoring
secrets:                           # aggregator
  postgresPassword: <generated>
  kcBootstrapAdminPassword: <generated>
  signalstackAdminKey: <generated>
  smtpUser / smtpPassword: ...
api / notification-service / match-score / search: { secrets: { ... } }   # signals

# global-cloud-values.yaml (cloud + computed)
global: { dataPlatform: { namespace: common-services, ... } }
postgres: { host: <RDS endpoint or in-cluster FQDN> }
aggregator-api / worker: { serviceAccount: { annotations: { eks.amazonaws.com/role-arn: <arn> } } }
ui: { hostBindings: "<multi-domain routing string>" }
```

Result: one source of truth, no `--set` flags, no kubectl-secret fetches.

`install.sh preflight` fails if the two generated files are missing — run
`bash install.sh create_tf_resources` (or `bash install.sh apply_tf_output_file`
to regenerate just them) first.

## Ingress host names

Public FQDNs are **not** derived or hard-coded in the charts — they are set as
anchors in `opentofu/aws/<env>/global-values.yaml` and referenced throughout it,
then flow into the generated files:

```yaml
# opentofu/aws/<env>/global-values.yaml — "Environment inputs" block (edit here)
_signals_public_hosts: &signals_public_hosts
  - "signals.example.com"
  - "api.signals.example.com"
_signals_host_bindings: &signals_host_bindings ""    # "host1=network/domain;host2=..." for multi-domain; empty = single-host
_aggregator_host:       &aggregator_host       "aggregator.example.com"
_grafana_host:          &grafana_host          "monitoring.example.com"
```

| Anchor | Used as | Lands in |
|--------|---------|----------|
| `_signals_public_hosts` | signals public hosts (list) | signals `publicHosts` (api + ui ingress) |
| `_signals_host_bindings` | multi-domain host→network/domain routing | `ui.hostBindings` (via `global-cloud-values.yaml`) |
| `_aggregator_host` | aggregator host | aggregator `global.publicHost` (api + web share it) |
| `_grafana_host` | Grafana host | monitoring Grafana ingress |

Change a host anchor, re-run `bash install.sh apply_tf_output_file` to regenerate
the generated files, then redeploy the affected release. Point DNS for these
hosts at the **Kong proxy** LoadBalancer created by `common-services`:

```bash
kubectl -n common-services get svc common-services-kong-proxy   # external hostname
```

## Prerequisites

- Kubernetes 1.24+ (EKS provisioned via `opentofu/aws/template`)
- `kubectl` with current-context pointed at the target cluster
- `helm` v3.12+
- `terragrunt` + `tofu` for generating the values files
- DNS A/CNAME records for the host anchors in `global-values.yaml`, pointing at
  the Kong proxy LoadBalancer created by `common-services`

(`yq` is **no longer required** — slicing is gone.)

## Quick start

```bash
# 1. Bootstrap a new environment from the template
cp -R opentofu/aws/template opentofu/aws/dev   # or staging/, prod/, ...
cd opentofu/aws/dev

# 2. (Optional) edit dev/global-values.yaml anchors to override defaults

# 3. Provision cloud + generate the values files
#    (no-arg install.sh runs the full infra bootstrap)
bash install.sh
#    ...or just regenerate the generated values files:
#    bash install.sh apply_tf_output_file

# 4. Create namespaces + ghcr-pull secret, then install all releases
GHCR_PAT=ghp_xxx bash install.sh deploy_all_services
```

`install.sh` auto-derives all paths from its own location, so no edits are
required when cloning template → dev/staging/prod.

`deploy_all_services` chains: `preflight → create_namespaces_and_secrets →
deploy_monitoring → deploy_common_services → deploy_signals → deploy_aggregator →
fix_acme_issuer_uri`, each helm step with a readiness `--wait`.
`deploy_common_services` applies the gp3 default StorageClass **and the Kong
CRDs** first (shared Postgres/Redis PVCs bind to gp3; helm skips subchart/upgrade
CRDs so Kong's must be applied explicitly).

### Per-chart commands

```bash
bash install.sh deploy_monitoring
bash install.sh deploy_common_services
bash install.sh deploy_signals
bash install.sh deploy_aggregator
```

### Image-pull secret only

```bash
GHCR_PAT=ghp_xxx bash install.sh create_namespaces_and_secrets   # PAT via env
bash install.sh create_namespaces_and_secrets                    # interactive prompt
```

### Checks (no install)

```bash
bash install.sh preflight   # tooling + cluster + generated values files present
bash install.sh lint        # helm lint all four charts
bash install.sh dry_run     # helm --dry-run all four against the current cluster
```

Chain any functions: `bash install.sh lint dry_run`.

## Override the file paths, namespaces, and release names

If you keep the values files elsewhere (a separate secrets repo, manually
maintained files), point the script at them via env vars:

```bash
GLOBAL_SECRETS=/etc/bluedots/global-secrets.yaml \
GLOBAL_CLOUD_VALUES=/etc/bluedots/global-cloud-values.yaml \
GLOBAL_VALUES=/etc/bluedots/global-values.yaml \
GLOBAL_IMAGES=/etc/bluedots/global-images.yaml \
  bash install.sh deploy_all_services
```

Namespaces and release names are likewise overridable: `MON_NS`, `CS_NS`,
`SIGNALS_NS`, `AGG_NS`, and `MON_REL`, `CS_REL`, `SIGNALS_REL`, `AGG_REL`.

## Why this order

- **monitoring first.** Installs the Prometheus-operator CRDs (ServiceMonitor /
  PodMonitor / PrometheusRule) others rely on; metrics/alerts live from the start.
- **common-services next.** Kong ingress, `cert-manager`, the shared Postgres
  StatefulSet and shared Redis live here. Subsequent charts attach to them.
- **signals.** Self-contained app stack. Uses common-services Postgres user
  `dpg` (password = `credentials.dpgPassword`) and the shared Redis.
- **aggregator last.** Same dependency on common-services; uses Postgres user
  `aggregator` (password = `credentials.aggregatorPassword`). Longer rollout
  because the Keycloak init Job runs after Postgres is Ready.

## Rotation

Secrets are stable across `tofu apply`s — `random_id` / `random_password`
resources persist in terraform state. To rotate:

```bash
cd opentofu/aws/<env>
( cd random_passwords && terragrunt destroy )      # or taint one: tofu taint random_password.<name>
bash install.sh apply_tf_random_passwords apply_tf_output_file   # regenerate the generated files
bash install.sh deploy_all_services                # re-run all releases
```

Because the same tofu variable is templated into every place that needs it (e.g.
`signalstack_admin_key` lands in both `secrets.signalstackAdminKey` for aggregator
**and** the signals api secret), the releases never drift apart.

## Aggregator overrides applied in this repo

`helm/aggregator/values.yaml` is patched vs. upstream:

```yaml
ingress-nginx:
  enabled: false        # common-services owns the ingress controller cluster-wide
cert-manager:
  enabled: false        # common-services owns cert-manager + ClusterIssuer
```

The chart still vendors both subcharts under `charts/` (so it remains installable
standalone elsewhere), but they're inert here. The `templates/clusterissuer.yaml`
is gated on `cert-manager.enabled` and therefore renders nothing.

If you ever want to run `aggregator` against a cluster that has *no*
`common-services` chart, flip both flags back to `true` and skip
`deploy_common_services`.

## Cleanup

```bash
bash install.sh cleanup_all_services    # reverse order: aggregator → signals → common-services → monitoring
```

Individual:

```bash
bash install.sh destroy_aggregator
bash install.sh destroy_signals
bash install.sh destroy_common_services   # also runs cleanup_cert_manager_leftovers
bash install.sh destroy_monitoring
```

Each `destroy_*` uninstalls the release and deletes its namespace (which drops
that namespace's PVCs) — **destructive** for the data charts.
`destroy_common_services` additionally wipes cert-manager CRDs/ClusterIssuer
(they carry a "keep" policy and survive `helm uninstall`, otherwise bricking the
next install).

To tear down the cloud infra as well:

```bash
bash install.sh destroy_tf_resources
```

## Per-chart docs

- [`common-services/README.md`](./common-services/README.md) — platform tunables
  (LB annotations, ACME server, issuer name, DB sizing, Kong)
- `monitoring/values.yaml` — Prometheus/Loki/Alloy/Jaeger/Grafana config, alert rules
- `signals/values.yaml` — Signals image tags, hosts, runtime config, resource limits
- `aggregator/values.yaml` — aggregator hosts, Keycloak realm, SMTP, secrets

## Troubleshooting

- **`ERROR: values file not found: <path>`** (from `preflight`) — opentofu
  hasn't generated `global-secrets.yaml` / `global-cloud-values.yaml` yet.
  `cd opentofu/aws/<env>` then `bash install.sh create_tf_resources` (or
  `apply_tf_output_file`). Point the script elsewhere via
  `GLOBAL_SECRETS=... GLOBAL_CLOUD_VALUES=... bash install.sh ...` if they live
  elsewhere.
- **`ERROR: cluster unreachable`** (from `preflight`) — your kubeconfig
  current-context isn't pointed at the target cluster. Check `kubectl config
  current-context`.
- **`rotate-ghcr-pull.sh missing`** — run from the env directory that contains it
  (`opentofu/aws/<env>`); `install.sh` resolves it next to itself.
- **PVCs stuck `Pending`** — gp3 isn't the default StorageClass. Run
  `bash install.sh apply_gp3_default_sc` (also run automatically by
  `deploy_common_services`).
- **Certificates stuck `READY=False`** — cert-manager v1.20.2 ACME bug. Run
  `bash install.sh fix_acme_issuer_uri` (also run automatically at the end of
  `deploy_all_services`).
- **Kong controller crash-watching missing `KongClusterPlugin`/`KongPlugin`** —
  CRDs weren't applied. `bash install.sh deploy_common_services` applies them via
  `apply_kong_crds` (`kubectl apply --server-side -f common-services/crds/`).
```
