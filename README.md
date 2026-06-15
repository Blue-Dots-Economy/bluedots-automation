# bluedots-devops

Infrastructure-as-code and deployment tooling for the **Blue Dots Economy**
platform. This repo does two things:

1. **Provisions** an AWS EKS cluster (+ VPC, IAM/IRSA, S3, storage class) with
   **OpenTofu + Terragrunt** — see [`opentofu/`](#1-infrastructure--opentofuaws).
2. **Deploys** the application stack onto that cluster with **Helm** — three
   umbrella charts installed in a strict order — see [`helm/`](#2-application-stack--helm).

End-to-end flow: `opentofu/aws/dev` brings up the cluster → `make install`
from the repo root deploys the platform, **Signals**, and **Aggregator**.

---

## ⚠️ Read this first: names don't match directories

The single most confusing thing about this repo is that the **directory name,
the Helm chart name, the release name, and the namespace are all different** for
each component. Keep this table handy:

| Directory              | Chart `name`     | Release    | Namespace         | What it is                                                        |
|------------------------|------------------|------------|-------------------|-------------------------------------------------------------------|
| `helm/common-services` | `platform`       | `platform` | `common-services` | ingress-nginx, cert-manager, `letsencrypt-prod` issuer, **shared Postgres + Redis** |
| `helm/signals`         | `dpg`            | `dpg`      | `dpg`             | **Signals / signalstack** — api, ui, notification-service, match-score |
| `helm/aggregator`      | `aggregator-dpg` | `aggregator` | `aggregator`    | **Aggregator portal** — web (BFF), api, worker, keycloak          |

> **"Signals" lives in `helm/signals/` but the chart is called `dpg`.** When the
> Makefile, logs, or `helm list` say `dpg`, that means Signals.
>
> Note: the older [`helm/README.md`](helm/README.md) refers to the charts by
> their chart names (`platform` / `dpg` / `aggregator-dpg`) as if they were
> directories. The actual directories are `common-services` / `signals` /
> `aggregator`. The Makefile maps them correctly — trust the Makefile.

---

## Repository layout

```
.
├── Makefile                 # Helm deploy orchestrator (platform → dpg/signals → aggregator)
├── helm/                    # Application stack — three umbrella charts
│   ├── common-services/     # chart "platform": ingress-nginx, cert-manager, Postgres, Redis
│   ├── signals/             # chart "dpg": the Signals stack (api/ui/notification/match-score)
│   └── aggregator/          # chart "aggregator-dpg": web BFF, api, worker, keycloak
└── opentofu/
    └── aws/
        ├── _common/         # Terragrunt include files shared by every env (eks.hcl, iam.hcl, …)
        ├── modules/         # OpenTofu modules: network, eks, iam, storage, random_passwords, output-file
        ├── template/        # Reference environment — copy this to make a new env
        └── dev/             # The "dev" environment (active)
            ├── global-values.yaml   # ← the one file you edit to configure the whole cluster
            ├── install.sh           # one-shot: backend + apply + default StorageClass
            ├── create_tf_backend.sh # creates the S3 tfstate bucket
            ├── root.hcl             # Terragrunt backend/provider generation
            └── <module>/terragrunt.hcl  # one dir per module: network, eks, iam, storage, …
```

## Which branch?

`origin/dev` is the latest and is a **strict superset** of every other branch —
it carries both the Helm charts and the OpenTofu infra. `develop` has only the
infra, `helmcharts` has only the charts, `main` is the base. **Deploy from `dev`.**

```bash
git switch dev && git pull origin dev
```

---

## Prerequisites

| Tool        | Used for                                  | Min version |
|-------------|-------------------------------------------|-------------|
| `aws` CLI   | credentials, S3 tfstate bucket            | v2          |
| `opentofu`  | provisioning (via terragrunt)             | 1.6+        |
| `terragrunt`| OpenTofu orchestration across modules     | 0.55+       |
| `yq`        | reading `global-values.yaml` in scripts   | mikefarah 4 |
| `kubectl`   | talking to the cluster                    | matches EKS |
| `helm`      | deploying the charts                      | v3.12+      |
| `openssl`, `sed` | password generation in install scripts | —        |

Plus:
- AWS credentials configured (`aws configure` / SSO) with rights to create VPC, EKS, IAM, S3.
- A **GHCR pull token** (`read:packages`) — the app images live in private GHCR repos
  (`ghcr.io/blue-dots-economy/...`). See [Image pull secret](#image-pull-secret).
- **DNS records** pointing the public hostnames at the ingress LoadBalancer once it exists.

---

## 1. Infrastructure — `opentofu/aws`

Terragrunt-driven. Each module (`network`, `eks`, `iam`, `storage`,
`random_passwords`, `output-file`) is its own directory under an environment;
they all `include` the shared logic in `_common/*.hcl` and read configuration
from a single `global-values.yaml`.

### Configure

Edit **`opentofu/aws/dev/global-values.yaml`** — this is the only file you
normally touch. Key settings (current `dev` values shown):

```yaml
global:
  building_block: "purple-dots"        # naming prefix for all AWS resources
  environment: "dev"                   # 1–9 lowercase alphanumeric
  cloud_storage_region: "ap-south-1"
  create_network: true                 # false → supply existing vpc_id / subnet_ids
  eks_cluster_version: "1.35"
  eks_node_instance_type: "t3.large"   # 2 vCPU / 8 GB
  eks_node_count_min: 1
  eks_node_count_max: 2
  service_account_subjects:            # IRSA principals allowed to assume the app role
    - "system:serviceaccount:aggregator:aggregator-api"
    - "system:serviceaccount:aggregator:aggregator-worker"
```

The file is heavily commented (subnets, NAT gateway, S3 buckets, CloudWatch
observability) — read it before applying.

### Provision

```bash
cd opentofu/aws/dev
./install.sh
```

`install.sh` runs, in order:
1. **`create_tf_backend.sh`** — creates an encrypted, versioned, private S3 bucket
   `purple-dots-dev-<account_id>-tfstate` for OpenTofu state, and writes `tf.sh`
   with `AWS_REGION` / `TERRAFORM_BACKEND_BUCKET`.
2. **Backs up** any existing `~/.kube/config`.
3. **`terragrunt run --all init/apply`** — provisions network → EKS → IAM →
   storage, and writes a fresh kubeconfig.
4. **Applies `gp3-sc.yaml`** as the default StorageClass (and demotes `gp2`).

Targeted re-runs are supported, e.g. `./install.sh create_tf_resources`.

### Tear down

```bash
cd opentofu/aws/dev
./install.sh destroy_tf_resources
```

> **State & secrets are gitignored.** `.terraform/`, `*.tfstate`, `*.tfvars`,
> lock files, and the generated `tf.sh` / `global-cloud-values.yaml` never get
> committed (see `.gitignore`). State lives in S3.

### New environment

Copy `opentofu/aws/template/` to `opentofu/aws/<env>/`, edit its
`global-values.yaml`, and run its `install.sh`.

---

## 2. Application stack — Helm

Once `kubectl` points at the cluster, deploy from the **repo root**:

```bash
make install        # platform → dpg (Signals) → aggregator, with readiness waits
```

`make help` lists every target. The deploy order is mandatory.

### Why the order matters

1. **`platform` first** — owns the cluster-wide `ingress-nginx` controller,
   `cert-manager`, the `letsencrypt-prod` ClusterIssuer, **and the shared
   Postgres + Redis** that the other two stacks connect to. Install it once.
   Without it, the other charts' Ingresses sit Pending and ACME challenges fail.
2. **`dpg` (Signals) second** — connects to the shared DBs at
   `platform-postgresql.common-services.svc` / `platform-redis-master.common-services.svc`.
3. **`aggregator` last** — same shared DBs; longest rollout (Keycloak init Job
   runs after Postgres is Ready).

`ingress-nginx` and `cert-manager` are vendored as subcharts inside
`aggregator` too, but disabled there (`enabled: false`) so `platform` owns them
cluster-wide.

### Per-chart targets

```bash
make platform-install        # helm/common-services  → release "platform"  / ns common-services
make dpg-install             # helm/signals          → release "dpg"        / ns dpg     (Signals)
make aggregator-install      # helm/aggregator        → release "aggregator" / ns aggregator
```

Each install target pulls the DB passwords generated by `platform` out of the
`data-postgres` / `data-redis` Secrets in `common-services` and passes them
through, so it errors clearly if you skip `platform-install`.

### Static checks (no cluster needed)

```bash
make lint        # helm lint all three charts
make template    # render all three (smoke test)
make dry-run     # helm --dry-run against the current cluster (needs kubeconfig)
```

### Tear down

```bash
make uninstall            # reverse order: aggregator → dpg → platform
# or individually:
make aggregator-uninstall
make dpg-cleanup          # DESTRUCTIVE: deletes Postgres/Redis PVCs + scrubs generated passwords
make platform-uninstall
```

---

## Images & registries

App images are referenced in each chart's `values.yaml`. Tags are pinned per
component (override per environment with `--set` or an extra `-f` values file):

| Component             | Image                                                  |
|-----------------------|--------------------------------------------------------|
| Signals — api         | `ghcr.io/blue-dots-economy/signals-dpg/api`            |
| Signals — ui          | `vinodbbhorge/signalstack-ui`                          |
| Signals — notification / match-score | `vinodbbhorge/notification-service` / `vinodbbhorge/match-scoring` |
| Aggregator — web / api / worker | `ghcr.io/blue-dots-economy/aggregator-dpg/{web,api,worker}` |
| Aggregator — keycloak | `vinodbbhorge/aggregator-dpg-keycloak`                 |

### Image pull secret

The `ghcr.io/blue-dots-economy/*` images are private. Each app chart references a
pull secret named `ghcr-pull`. Either pre-create it, or let the chart render it:

```bash
# pre-create (recommended):
kubectl create secret docker-registry ghcr-pull \
  -n dpg --docker-server=ghcr.io \
  --docker-username=<gh-user> --docker-password=<GHCR_PAT_read:packages>
# repeat for the aggregator namespace.
```

Helper scripts `helm/signals/rotate-ghcr-pull.sh` and
`helm/aggregator/rotate-ghcr-pull.sh` rotate these. **Never commit a PAT** —
pass it via `--set` at install time.

## Secrets & credentials

- **`platform`** generates the Postgres (admin/aggregator/dpg) and Redis
  passwords on first install and stores them in the `data-postgres` /
  `data-redis` Secrets in the `common-services` namespace. Re-runs reuse them.
- **`helm/signals/install.sh`** generates `PG_PW` / `REDIS_PW` / `AUTH_SECRET`
  into `helm/signals/values.yaml` on first run. **Do not commit a populated
  `values.yaml`** — `make dpg-cleanup` scrubs the placeholders back to empty.
- **`helm/aggregator/values.yaml`** ships `change-me-*` placeholders (SMTP,
  Keycloak, secrets) that must be replaced before any real rollout — ideally via
  an out-of-band Secret rather than inline.

## Hostnames

Set the public hostnames in each chart's `values.yaml` (e.g. aggregator's
`global.publicHost`, currently `purpledots.servehalflife.com`) and create DNS
records pointing at the `ingress-nginx` LoadBalancer hostname after
`make platform-install`.

---

## Quick reference

```bash
# Infra
cd opentofu/aws/dev && ./install.sh                 # provision EKS
cd opentofu/aws/dev && ./install.sh destroy_tf_resources

# Apps (from repo root, kubeconfig pointed at the cluster)
make install                                        # full stack, in order
make platform-install / dpg-install / aggregator-install
make lint / template / dry-run                      # checks
make uninstall                                      # full teardown (reverse order)

# Inspect
kubectl -n common-services get pods,svc
kubectl -n dpg get pods,svc,ingress                 # Signals
kubectl -n aggregator get pods,svc,ingress
helm list -A
```
