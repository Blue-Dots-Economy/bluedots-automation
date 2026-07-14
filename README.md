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
├── .github/
│   ├── actions/pr-gate/      # composite action: docs + release-notes gate for develop PRs
│   ├── workflows/            # develop-pr-gate.yml (gate), pr-gate-tests.yml (action unit tests)
│   └── PULL_REQUEST_TEMPLATE.md  # Summary / Release Notes / Checklist
├── DEPLOYMENT.md             # authoritative end-to-end runbook + troubleshooting
├── helm/                     # Application stack — four umbrella charts
│   ├── global-resources.yaml # shared replica/HPA/PDB/resource overrides (all envs)
│   ├── monitoring/           # chart "monitoring": kube-prometheus-stack, Loki, Alloy, Jaeger, Grafana
│   ├── common-services/      # chart "platform": Kong, cert-manager, Postgres, Redis, metrics-server
│   ├── signals/              # chart "dpg": Signals (api/ui/notification/match-score); charts/api/files/{networks,consent}/*.json
│   └── aggregator/           # chart "aggregator-dpg": web BFF, api, worker, keycloak; files/consent/consent.json
└── opentofu/
    └── aws/
        ├── _common/          # Terragrunt include files shared by every env (eks.hcl, iam.hcl, bastion.hcl, pritunl.hcl, …)
        ├── modules/          # OpenTofu modules: network, eks, iam, storage, random_passwords, rds, output-file, bastion, pritunl
        └── template/         # Reference environment — copy this to make a new env (e.g. dev/)
            ├── install.sh           # ← single entrypoint: infra bootstrap + Helm deploy (function dispatcher)
            ├── global-values.yaml   # ← the one file you edit (anchors at the top)
            ├── global-images.yaml   # per-env image repository/tag/pullPolicy
            ├── create_tf_backend.sh # creates the S3 tfstate bucket
            ├── get-signalstack-org-id.sh  # fetch actingOrgId after signals is up
            ├── rotate-ghcr-pull.sh  # write/refresh the ghcr-pull image-pull secret
            ├── gp3-sc.yaml          # gp3 StorageClass (made cluster-default)
            ├── root.hcl             # Terragrunt backend/provider generation
            └── <module>/terragrunt.hcl  # one dir per module: network, eks, iam, storage, rds, bastion, pritunl, …
```

> **Private-cluster access** is provided by two optional infra modules —
> **`pritunl`** (a Pritunl OpenVPN host in a public subnet, with an Elastic IP)
> and **`bastion`** (a deploy workstation in a *private* subnet, no public IP,
> reachable only over the VPN). See [Private-cluster access](#private-cluster-access-pritunl-vpn--bastion).

> On trunk branches only `template/` exists. Per-deployment branches carry their
> own `opentofu/aws/<env>/` directory (e.g. `dev/`). Copy `template/` to create one.

### The values-file model

Config is **never hand-edited into chart `values.yaml`**. Each `helm upgrade`
layers files via repeated `-f` (last wins):

| File | Source | Committed? | Holds |
|------|--------|-----------|-------|
| `helm/global-resources.yaml`      | in repo, shared       | yes | replicas, HPA, PDB, container resources (incl. explicit CPU/mem requests+limits for `common-services`: Kong `replicaCount: 2`, cert-manager, Redis, `postgresBootstrap`, metrics-server) |
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

### Consent config (delivered via ConfigMap)

Consent text/versions are **served from a ConfigMap**, not baked into images, so
they can change with an edit + rollout (no image rebuild). This repo is the
downstream sync — the canonical consent content lives in the app repos; here you
just deliver it:

- **Signals** — source files in `helm/signals/charts/api/files/consent/<network>.json`
  (plus an optional brand override `<network>.<brand>.json`). Select them with
  `api.schemas.consentNetwork` / `api.schemas.consentBrand` in `global-values.yaml`.
  The `schemas-configmap` mounts `consent.json` (and, for a brand, a nested
  `<brand>/consent.json`) alongside the network schemas at `/app/schemas`; the api
  reads it because `CONSENT_CONFIG_SOURCE: local` is set explicitly. Consent is
  cached in-process, so a `checksum/schemas` pod annotation rolls the api pods
  whenever the consent (or network) files change.
- **Aggregator** — source file in `helm/aggregator/files/consent/consent.json`,
  rendered into a `{release}-consent` ConfigMap and mounted single-file (subPath)
  into both the web and api pods at
  `/app/config/<network>[/<brand>]/schemas/aggregator/consent.json`. subPath does
  not hot-update, so a consent change needs a rollout restart of web + api.

> `consent_text` no longer appears in the deployed `network.json` — consent is
> served through the consent ConfigMap above, so its absence from network config
> is **expected, not a gap**. Network schemas (`network.json`) remain sourced
> upstream from Signals-DPG; this repo only syncs the deployed copy.

**Support/grievance email is deploy-time configurable.** The consent JSON carries
a `__SUPPORT_EMAIL__` placeholder in its T&C / Privacy / Grievances copy; the
ConfigMap render substitutes it with `api.schemas.consentSupportEmail` (signals)
or `global.consentSupportEmail` (aggregator) — both default to
`hello@bluedotseconomy.org`. Change the email in that one value, **never** in the
consent content, so a brand/network switch keeps the right contact address.

The Signals migrate Job creates the `consent_record` ledger table from the bundled
`helm/signals/charts/api/files/schema.sql` — refresh that bundle when the upstream
schema changes.

### Org hierarchy

`global.orgHierarchyEnabled` (in `global-values.yaml`, default `true`) is surfaced
to the aggregator web + api pods as the `ORG_HIERARCHY_ENABLED` env var (via their
ConfigMaps), enabling the org-hierarchy features in the aggregator app.

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

## Contributing: the develop-PR gate

PRs targeting **`develop`** run the `develop-pr-gate` workflow
(`.github/workflows/develop-pr-gate.yml`), a composite action in
`.github/actions/pr-gate/`. It **fails closed** unless the PR has both:

1. A non-empty `## Release Notes` section in the PR description (use the
   [PR template](.github/PULL_REQUEST_TEMPLATE.md)), and
2. A change to `README.md` or `CLAUDE.md`.

Each condition is waivable with a label: `no-release-notes` and `no-doc-update`.
The gate logic is pure JS (`gate.mjs`) with unit tests (`gate.test.mjs`) run by a
separate `pr-gate-tests` workflow on changes under `.github/actions/pr-gate/`.

> The gate is only enforced once a branch-protection / ruleset requires the
> `develop-pr-gate` check on `develop` — configure that at the org/repo level.

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
`random_passwords`, `rds`, `output-file`, plus the optional `bastion` and
`pritunl`) is its own directory under an environment; they all `include` the
shared logic in `_common/*.hcl` and read configuration from a single
`global-values.yaml`.

The `network` module splits the VPC into **public** and **private** subnets:
public subnets carry the internet gateway and one **NAT gateway per AZ** (HA
egress); private subnets are `private-eks-*` (sized for EKS nodes; the EKS module
auto-selects these) and the smaller `/28` RDS subnets. `nat_gateway_enabled`
(default `true`) gives private subnets outbound internet. The EKS node group runs
in the `private-eks-*` subnets by default, with `eks_node_subnet_keys` to pin
nodes to a single AZ (EBS volumes are AZ-locked, so a single-node cluster must
stay put).

### Configure

Edit **`opentofu/aws/<env>/global-values.yaml`** — this is the only file you
normally touch, and you only edit the **anchors at the top**. Key settings:

```yaml
_building_block:         &building_block         "purple-dots"   # naming prefix for all AWS resources
_environment:            &environment            "dev"           # 1–9 lowercase alphanumeric
_cloud_storage_region:   &cloud_storage_region   "ap-south-1"
_eks_cluster_version:    &eks_cluster_version    "1.35"
_eks_node_instance_type: &eks_node_instance_type "m6a.xlarge"
_eks_node_disk_size_gb:  &eks_node_disk_size_gb  40
_eks_node_capacity_type: &eks_node_capacity_type "ON_DEMAND"  # or SPOT (cheaper; pilot opt-in on the pilot branch)
_eks_node_count_min:     &eks_node_count_min     1
_eks_node_count_max:     &eks_node_count_max     2
_aggregator_host:        &aggregator_host        "aggregator.domain.com"
_grafana_host:           &grafana_host           "monitoring.domain.com"
# plus _signals_public_hosts, _network, _brand, SMTP, MSG91, alert emails, RDS sizing, IRSA subjects
# global.orgHierarchyEnabled (default true) and api.schemas.consentNetwork/consentBrand also live here
# bastion_enabled / pritunl_enabled (default true), pritunl_ingress_cidrs, bastion_authorized_keys also live here
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
   (network → EKS → IAM → storage → random_passwords → rds → output-file, plus
   `pritunl` after network and `bastion` after EKS), and writes a fresh
   kubeconfig. This also generates `global-credentials.yaml` and
   `global-cloud-values.yaml`. The `bastion`/`pritunl` units are skipped from
   `run --all` when `bastion_enabled`/`pritunl_enabled` is `false`.
3. **`apply_gp3_default_sc`** — makes `gp3` the default StorageClass (demotes `gp2`).

Targeted re-runs are supported, e.g. `bash install.sh create_tf_resources`, or a
single module: `bash install.sh apply_tf_output_file` (regenerate just the
values files), `bash install.sh apply_tf_pritunl` / `apply_tf_bastion` (bring up
just the VPN/bastion — these ignore the `*_enabled` flag). The VPN/bastion pair
can also be torn down on their own: `bash install.sh destroy_tf_pritunl` /
`destroy_tf_bastion`.

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

For a full new-instance / new-network launch (network.json, brand, terms &
policies, domains, auth channels, and all per-instance config as one checklist),
follow **[docs/instance-setup.md](docs/instance-setup.md)**.

### Private-cluster access (Pritunl VPN + bastion)

Two optional modules make the cluster reachable without a public EKS endpoint or
any public-facing box you deploy from:

- **`pritunl`** — a Pritunl OpenVPN server on an Ubuntu host in a **public**
  subnet with an Elastic IP. It routes the VPC CIDR to a connected laptop, so it
  is the single front door for all cluster access. Set `pritunl_enabled` (default
  `true`), `pritunl_instance_type` (default `t3.small` — MongoDB needs ~1 GB), and
  `bastion_authorized_keys` (the SSH keys used for the one-time setup shell). The
  security group opens **SSH 22, OpenVPN 1194 (UDP+TCP), and web-admin 443** to
  `pritunl_ingress_cidrs` — which **defaults to `0.0.0.0/0` (open to the
  internet)**. Restrict it to office/home CIDRs and re-apply, since this SG gates
  all downstream cluster access.
- **`bastion`** — an Amazon-Linux-2023 deploy workstation in a **private** subnet
  with **no public IP** (reachable only over the VPN). Its SG allows SSH from the
  VPC CIDR only. It ships kubectl/helm/aws-cli/k9s/git/yq and, because it applies
  after EKS, pre-runs `aws eks update-kubeconfig` at boot — so `kubectl`/`helm`
  work the moment you SSH in. It is mapped into the cluster with cluster-wide
  `AmazonEKSClusterAdminPolicy` via an EKS access entry. Set `bastion_enabled`
  (default `true`), `bastion_instance_type` (default `t3.medium` — `nano` OOMs on
  `helm template`), and the same `bastion_authorized_keys`.

Access is by SSH **public** key only (each developer keeps their private key;
nothing secret lands in Terraform state). Add/remove a key or CIDR in
`global-values.yaml` and re-apply `pritunl`/`bastion` to grant/revoke.

> To go fully private, first set both `eks_endpoint_public_access` **and**
> `eks_endpoint_private_access` `true`, verify from the bastion, then flip
> `eks_endpoint_public_access` to `false`.

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
   by default.) The stock kube-prometheus ruleset is **disabled**
   (`defaultRules.create: false`) in favour of a curated
   `additionalPrometheusRulesMap` set (the noisy per-API Kong rate-limit alerts
   were dropped) — see [`helm/monitoring/README.md`](helm/monitoring/README.md).
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
| Signals — notification | `ghcr.io/blue-dots-economy/notification-service` |
| Signals — match-score  | `vinodbbhorge/match-scoring`                            |
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
