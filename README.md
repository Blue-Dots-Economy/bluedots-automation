# bluedots-automation

Infrastructure-as-code and deployment tooling for the **Blue Dots Economy**
platform. This repo does two things:

1. **Provisions** an AWS EKS cluster (+ VPC, IAM/IRSA, S3, storage class) with
   **OpenTofu + Terragrunt** — see [`opentofu/`](#1-infrastructure--opentofuaws).
2. **Deploys** the application stack onto that cluster with **Helm** — four
   umbrella charts installed in a strict order — see [`helm/`](#2-application-stack--helm).

Both are driven by a single **`install.sh`** that lives in the per-environment
directory (`opentofu/aws/<env>/install.sh`). End-to-end flow:
`cd opentofu/aws/<env> && bash install.sh` brings up the cluster →
`bash install.sh deploy_all_services` deploys monitoring, common-services,
Signals, and Aggregator.

> **There is no Makefile.** `install.sh` is the only entrypoint for both infra
> and Helm. For the full step-by-step runbook (with validation and
> troubleshooting), see **[DEPLOYMENT.md](DEPLOYMENT.md)**.

---

## ⚠️ Read this first: names don't match directories

Release name and namespace now **match the directory name**. The one thing that
still differs is the Helm **chart name** (`name:` in `Chart.yaml`) — and it
differs for every app chart. So when `helm list`, logs, or templates say `dpg`,
that means **Signals** (`helm/signals/`).

| Directory               | Chart `name`     | Release           | Namespace         | What it is                                                              |
|-------------------------|------------------|-------------------|-------------------|-------------------------------------------------------------------------|
| `helm/monitoring`       | `monitoring`     | `monitoring`      | `monitoring`      | Prometheus + Alertmanager + Loki + Alloy + Jaeger + Grafana             |
| `helm/common-services`  | `platform`       | `common-services` | `common-services` | **Kong** ingress, cert-manager, `letsencrypt-prod` issuer, **shared Postgres + Redis**, metrics-server |
| `helm/signals`          | `dpg`            | `signals`         | `signals`         | **Signals / signalstack** — api, ui, notification-service, match-score  |
| `helm/aggregator`       | `aggregator-dpg` | `aggregator`      | `aggregator`      | **Aggregator portal** — web (BFF), api, worker, keycloak                |

> **"Signals" lives in `helm/signals/` but the chart is called `dpg`.** When
> logs or `helm list` say `dpg`, that means Signals. The older
> [`helm/README.md`](helm/README.md) refers to charts by their chart names
> (`platform` / `dpg` / `aggregator-dpg`) as if they were directories — trust
> `install.sh`, which maps everything correctly.

---

## Repository layout

```
.
├── DEPLOYMENT.md             # authoritative end-to-end runbook + troubleshooting
├── helm/                     # Application stack — four umbrella charts
│   ├── global-resources.yaml # shared replica/HPA/PDB/resource overrides (all envs)
│   ├── monitoring/           # chart "monitoring": kube-prometheus-stack, Loki, Alloy, Jaeger, Grafana
│   ├── common-services/      # chart "platform": Kong, cert-manager, Postgres, Redis, metrics-server
│   ├── signals/              # chart "dpg": the Signals stack (api/ui/notification/match-score)
│   └── aggregator/           # chart "aggregator-dpg": web BFF, api, worker, keycloak
└── opentofu/
    └── aws/
        ├── _common/          # Terragrunt include files shared by every env (eks.hcl, iam.hcl, …)
        ├── modules/          # OpenTofu modules: network, eks, iam, storage, random_passwords, rds, output-file
        └── template/         # Reference environment — copy this to make a new env (e.g. dev/)
            ├── install.sh           # ← single entrypoint: infra bootstrap + Helm deploy (function dispatcher)
            ├── global-values.yaml   # ← the one file you edit (anchors at the top)
            ├── global-images.yaml   # per-env image repository/tag/pullPolicy
            ├── create_tf_backend.sh # creates the S3 tfstate bucket
            ├── get-signalstack-org-id.sh  # fetch actingOrgId after signals is up
            ├── rotate-ghcr-pull.sh  # write/refresh the ghcr-pull image-pull secret
            ├── gp3-sc.yaml          # gp3 StorageClass (made cluster-default)
            ├── root.hcl             # Terragrunt backend/provider generation
            └── <module>/terragrunt.hcl  # one dir per module: network, eks, iam, storage, rds, …
```

> On trunk branches only `template/` exists. Per-deployment branches carry their
> own `opentofu/aws/<env>/` directory (e.g. `dev/`). Copy `template/` to create one.

### The values-file model

Config is **never hand-edited into chart `values.yaml`**. Each `helm upgrade`
layers files via repeated `-f` (last wins):

| File | Source | Committed? | Holds |
|------|--------|-----------|-------|
| `helm/global-resources.yaml`      | in repo, shared       | yes | replicas, HPA, PDB, container resources |
| `<env>/global-images.yaml`        | in repo, per-env      | yes | image `repository` / `tag` / `pullPolicy` |
| `<env>/global-values.yaml`        | in repo, **you edit** | yes | all user config (hosts, network/brand, SMTP/MSG91, RDS sizing, app config) — edit the **anchors at the top** |
| `<env>/global-credentials.yaml`   | **generated** by tofu (`output-file`) | **no** (gitignored) | all secrets (PG/Redis/auth passwords) |
| `<env>/global-cloud-values.yaml`  | **generated** by tofu (`output-file`) | **no** (gitignored) | cloud outputs + computed config (S3 bucket/region, IRSA ARN, computed hosts/origins, RDS Postgres host when provisioned) |

Every file keys its values at root level by chart (e.g. `api:`, `ui:`,
`aggregator-api:`, `alerting:`), so each `-f` feeds Helm directly — **no `yq`
slicing** (which is why `install.sh preflight` no longer needs `yq`).

**`global-values.yaml` is anchors-only:** a top "Environment inputs" block
defines YAML anchors (`_building_block`, `_environment`, `_signals_public_hosts`,
`_aggregator_host`, `_grafana_host`, `_network`, `_brand`, SMTP, MSG91, alert
emails, EKS/RDS sizing) and everything under `global:` references them. Edit the
anchors at the top only.

---

## Which branch?

There are two kinds of branches: **trunk** branches that integrate work, and
**per-deployment** branches that hold one deployment's config.

### Trunk: where work is integrated

Work flows up a promotion chain. **`main` is the canonical branch** — it is the
standard you branch a new deployment from.

```
<your-feature-branch>  →  feature  →  develop  →  main
   (one branch per task)   integration   pre-release   canonical/standard
```

- **`main`** — the standard. New deployment branches are cut from here.
- **`develop`** — pre-release integration.
- **`feature`** — where in-progress work is collected before promotion. At any
  given time this is usually the *newest* trunk branch, so check it if you need
  the latest unreleased changes.

```bash
git switch main && git pull origin main
```

### Per-deployment branches

Each live deployment is maintained on its **own long-lived branch**, branched
from the trunk and carrying only that deployment's config (network JSON schemas,
image tags, public hostnames, and its own `opentofu/aws/<env>/` directory).
**Do not deploy a customer environment from `main`** — use its branch:

| Branch              | Environment | Notes                                              |
|---------------------|-------------|----------------------------------------------------|
| `blue-dots-dev`     | dev         |                                                    |
| `orange-dots-dev`   | dev         |                                                    |
| `orange-dot-prod`   | prod        | carries Kong ingress (`kong-nginx-impl`)           |
| `purple-dots-prod`  | prod        | **legacy** — still on the old `helmcharts/` layout |

---

## Prerequisites

| Tool        | Used for                                  | Min version |
|-------------|-------------------------------------------|-------------|
| `aws` CLI   | credentials, S3 tfstate bucket            | v2          |
| `tofu` (OpenTofu) | provisioning (via terragrunt)       | 1.6+        |
| `terragrunt`| OpenTofu orchestration across modules     | 0.90+       |
| `kubectl`   | talking to the cluster                    | ≥ 1.24 (matches EKS) |
| `helm`      | deploying the charts                      | v3.12+      |
| `bash`      | runs `install.sh`                         | 4.x+        |

> `yq` is **no longer required** — per-chart value slicing was removed; the tofu
> `output-file` module emits root-level files directly.

Plus:
- AWS credentials configured (`aws configure` / SSO) with rights to create VPC, EKS, IAM, S3.
- A **GHCR pull token** (`read:packages`, exported as `GHCR_PAT`) — the app images live in private GHCR repos (`ghcr.io/blue-dots-economy/...`). See [Image pull secret](#image-pull-secret).
- **DNS records** pointing the public hostnames at the Kong proxy LoadBalancer once it exists.

---

## 1. Infrastructure — `opentofu/aws`

Terragrunt-driven. Each module (`network`, `eks`, `iam`, `storage`,
`random_passwords`, `rds`, `output-file`) is its own directory under an
environment; they all `include` the shared logic in `_common/*.hcl` and read
configuration from a single `global-values.yaml`.

### Configure

Edit **`opentofu/aws/<env>/global-values.yaml`** — this is the only file you
normally touch, and you only edit the **anchors at the top**. Key settings:

```yaml
_building_block:         &building_block         "purple-dots"   # naming prefix for all AWS resources
_environment:            &environment            "dev"           # 1–9 lowercase alphanumeric
_cloud_storage_region:   &cloud_storage_region   "ap-south-1"
_eks_cluster_version:    &eks_cluster_version    "1.35"
_eks_node_instance_type: &eks_node_instance_type "m6a.large"
_eks_node_count_min:     &eks_node_count_min     1
_eks_node_count_max:     &eks_node_count_max     2
_aggregator_host:        &aggregator_host        "aggregator.domain.com"
_grafana_host:           &grafana_host           "monitoring.domain.com"
# plus _signals_public_hosts, _network, _brand, SMTP, MSG91, alert emails, RDS sizing, IRSA subjects
```

The file is heavily commented — read it before applying.

### Provision

```bash
cp -R opentofu/aws/template opentofu/aws/dev   # or use template/ directly
cd opentofu/aws/dev
bash install.sh
```

`install.sh` (no args) runs, in order:
1. **`create_tf_backend`** — creates an encrypted, versioned, private S3 bucket
   for OpenTofu state, and writes `tf.sh` with `AWS_REGION` / `TERRAFORM_BACKEND_BUCKET`.
2. **`create_tf_resources`** — `source tf.sh` then `terragrunt run --all apply`
   (network → EKS → IAM → storage → random_passwords → rds → output-file), and
   writes a fresh kubeconfig. This also generates `global-credentials.yaml` and
   `global-cloud-values.yaml`.
3. **`apply_gp3_default_sc`** — makes `gp3` the default StorageClass (demotes `gp2`).

Targeted re-runs are supported, e.g. `bash install.sh create_tf_resources`, or a
single module: `bash install.sh apply_tf_output_file` (regenerate just the
values files).

### Tear down

```bash
cd opentofu/aws/<env>
bash install.sh destroy_tf_resources
```

> **State & secrets are gitignored.** `.terraform/`, `*.tfstate`, `*.tfvars`,
> lock files, and the generated `tf.sh` / `global-cloud-values.yaml` /
> `global-credentials.yaml` never get committed (see `.gitignore`). State lives in S3.

### New environment

Copy `opentofu/aws/template/` to `opentofu/aws/<env>/` (env name = directory
basename), edit its `global-values.yaml`, and run its `install.sh`.

---

## 2. Application stack — Helm

Once `kubectl` points at the cluster, deploy from the **environment directory**:

```bash
cd opentofu/aws/<env>
export GHCR_PAT=ghp_xxx                 # read:packages token for image pulls
bash install.sh deploy_all_services     # full stack, in order, with readiness waits
```

`deploy_all_services` chains:
`preflight → create_namespaces_and_secrets → deploy_monitoring →
deploy_common_services → deploy_signals → deploy_aggregator → fix_acme_issuer_uri`.

### Why the order matters

1. **`monitoring` first** — its `kube-prometheus-stack` also ships the
   ServiceMonitor/PodMonitor/PrometheusRule CRDs the rest of the stack uses, and
   metrics/alerts are live from the start. (Functionally optional, deployed first
   by default.)
2. **`common-services`** — owns the cluster-wide **Kong** ingress controller,
   `cert-manager`, the `letsencrypt-prod` ClusterIssuer, **and the shared
   Postgres + Redis** the app stacks connect to. Without it, the other charts'
   Ingresses sit Pending and ACME challenges fail.
3. **`signals`** — connects to the shared DBs in `common-services`.
4. **`aggregator`** — same shared DBs; longest rollout (Keycloak init Job runs
   after Postgres is Ready).

`ingress-nginx` and `cert-manager` are vendored as subcharts inside `aggregator`
too, but disabled there (`enabled: false`) so `common-services` owns them
cluster-wide.

> **Ingress is Kong, not nginx.** `common-services` vendors both subcharts but
> the committed default is Kong (`kong.enabled: true`); `kong` is the
> cluster-default IngressClass and rate limiting is enforced via
> `KongClusterPlugin` tiers backed by the shared Redis. `deploy_common_services`
> applies the Kong CRDs first (Helm skips subchart/upgrade CRDs).

### Per-step targets

```bash
bash install.sh create_namespaces_and_secrets   # namespaces + ghcr-pull secret in each
bash install.sh deploy_monitoring
bash install.sh deploy_common_services           # applies gp3 + Kong CRDs, then helm --wait
bash install.sh deploy_signals
bash install.sh deploy_aggregator
```

After signals is up, fetch the aggregator's `actingOrgId`:

```bash
ORG_ID=$(./get-signalstack-org-id.sh)            # network_service org id
# set global.signalstack.actingOrgId in the aggregator config, then deploy aggregator
```

Without it, aggregator login fails with `SIGNALSTACK_ORG_NOT_REGISTERED`.

### Static checks (no cluster needed for lint)

```bash
bash install.sh lint        # helm lint all four charts
bash install.sh dry_run     # helm --dry-run all four against the current cluster (needs kubeconfig)
bash install.sh preflight   # verify helm + kubectl + cluster + generated values files
```

### Tear down

```bash
bash install.sh cleanup_all_services     # reverse order: aggregator → signals → common-services → monitoring
# or individually:
bash install.sh destroy_aggregator
bash install.sh destroy_signals
bash install.sh destroy_common_services  # DESTRUCTIVE: deletes namespace incl. Postgres/Redis PVCs
bash install.sh destroy_monitoring
```

---

## Images & registries

App images are pinned per component in `<env>/global-images.yaml` (override per
environment there):

| Component             | Image                                                  |
|-----------------------|--------------------------------------------------------|
| Signals — api         | `ghcr.io/blue-dots-economy/signals-dpg/api`            |
| Signals — ui          | `vinodbbhorge/signalstack-ui`                          |
| Signals — notification / match-score | `vinodbbhorge/notification-service` / `vinodbbhorge/match-scoring` |
| Aggregator — web / api / worker | `ghcr.io/blue-dots-economy/aggregator-dpg/{web,api,worker}` |
| Aggregator — keycloak | `vinodbbhorge/aggregator-dpg-keycloak`                 |

### Image pull secret

The `ghcr.io/blue-dots-economy/*` images are private. Each app chart references a
pull secret named `ghcr-pull`. `create_namespaces_and_secrets` creates it in
every namespace via `rotate-ghcr-pull.sh` using `$GHCR_PAT`:

```bash
export GHCR_PAT=ghp_xxxxxxxxxxxxxxxxxxxx   # read:packages
bash install.sh create_namespaces_and_secrets
```

**Never commit a PAT** — pass it via the `GHCR_PAT` env var.

## Secrets & credentials

- **Infra secrets** (Postgres admin/aggregator/dpg + Redis + auth passwords) are
  generated by the `random_passwords` + `output-file` tofu modules into the
  gitignored `global-credentials.yaml`, then stored at runtime in Kubernetes
  Secrets (`data-postgres` / `data-redis` in `common-services`). Re-runs reuse them.
- **SMTP / MSG91 / Google Maps keys** are set as anchors in `global-values.yaml`.

## Hostnames

Set the public hosts as anchors in `global-values.yaml`
(`_signals_public_hosts`, `_aggregator_host`, `_grafana_host`) and create DNS
records pointing at the **Kong proxy** LoadBalancer once it exists:

```bash
kubectl -n common-services get svc common-services-kong-proxy   # external hostname
```

---

## Quick reference

```bash
# Infra (from opentofu/aws/<env>)
bash install.sh                          # provision EKS (backend → apply → gp3)
bash install.sh destroy_tf_resources

# Apps (from opentofu/aws/<env>, kubeconfig pointed at the cluster)
export GHCR_PAT=ghp_xxx
bash install.sh deploy_all_services       # full stack, in order
bash install.sh deploy_common_services / deploy_signals / deploy_aggregator
bash install.sh lint / dry_run / preflight
bash install.sh cleanup_all_services      # full teardown (reverse order)

# Inspect
kubectl -n common-services get pods,svc
kubectl -n signals     get pods,svc,ingress   # Signals (chart "dpg")
kubectl -n aggregator  get pods,svc,ingress
kubectl -n monitoring  get pods
helm list -A
```

For the full runbook with validation steps and a troubleshooting table, see
**[DEPLOYMENT.md](DEPLOYMENT.md)**.
