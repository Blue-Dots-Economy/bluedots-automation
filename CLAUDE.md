# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**bluedots-automation** is an infrastructure-as-code and deployment system for the Blue Dots Economy platform. It does two things:

1. **Provisions AWS EKS infrastructure** using OpenTofu + Terragrunt (`opentofu/aws/`).
2. **Deploys the application stack** to Kubernetes using Helm (`helm/`).

---

## ⚠️ CRITICAL: Directory ≠ Chart ≠ Release ≠ Namespace

This is the most confusing aspect of the repo. **All four names differ** for each component:

| Directory | Chart Name | Release Name | Namespace | Purpose |
|-----------|-----------|-------------|-----------|---------|
| `helm/common-services/` | `platform` | `platform` | `common-services` | Cluster-wide: ingress-nginx, cert-manager, Postgres, Redis |
| `helm/signals/` | `dpg` | `dpg` | `dpg` | Signals stack (api, ui, notification, match-score) |
| `helm/aggregator/` | `aggregator-dpg` | `aggregator` | `aggregator` | Aggregator portal (web, api, worker, keycloak) |

When you see `helm list`, Makefile output, or kubectl logs say **`dpg`**, that's the **Signals component**, not a directory. The directory is `helm/signals/`.

---

## Deploy Order (STRICT)

The three charts **must** deploy in this exact order:

1. **`platform`** — owns cluster-wide ingress-nginx, cert-manager, and shared Postgres/Redis. Without it, other Ingresses sit Pending and ACME challenges fail.
2. **`dpg` (Signals)** — connects to shared DBs at `platform-postgresql.common-services.svc` / `platform-redis-master.common-services.svc`.
3. **`aggregator`** — same shared DBs; has the longest rollout (Keycloak init runs after Postgres is Ready).

---

## Common Commands

### Infrastructure Provisioning (OpenTofu)

```bash
# Provision the entire EKS cluster
cd opentofu/aws/dev
./install.sh

# Tear down everything
cd opentofu/aws/dev
./install.sh destroy_tf_resources

# Targeted re-runs
./install.sh create_tf_backend       # Create/recreate the S3 tfstate bucket
./install.sh create_tf_resources     # Provision (init + apply)
./install.sh apply_gp3_default_sc    # Set gp3 StorageClass default
```

`install.sh` runs in order: create S3 backend → backup kubeconfig → terragrunt apply → apply gp3 StorageClass.

### Application Deployment (Helm)

```bash
# Full stack in order (from repo root)
make install

# Individual components
make platform-install
make dpg-install
make aggregator-install

# Cleanup (reverse order)
make uninstall
# or individually:
make aggregator-uninstall
make dpg-cleanup        # DESTRUCTIVE: deletes PVCs + scrubs credentials
make platform-uninstall

# Static checks (no cluster needed)
make lint               # helm lint all three charts
make template           # helm template all three (smoke test)
make dry-run            # helm --dry-run against current cluster
```

---

## Architecture Layers

### OpenTofu/Terragrunt Structure

Located at `opentofu/aws/dev/`:

- **`global-values.yaml`** — the *only* file you edit. Controls cluster size, AWS region, instance types, node counts, IRSA subjects.
- **`root.hcl`** — Terragrunt backend/provider generation (generated from `global-values.yaml`).
- **Modules** (one dir per module: `network/`, `eks/`, `iam/`, `storage/`, `random_passwords/`, `output-file/`):
  - Each has its own `terragrunt.hcl` that includes shared logic from `_common/`.
  - All read from `global-values.yaml`.
  - Provision in order: network → EKS → IAM → storage.

**Key files:**
- `opentofu/aws/_common/{eks,network,storage,iam}.hcl` — included by every module, defines the shared configuration.
- `opentofu/aws/template/` — reference environment; copy to create new environments.

### Helm Stack Structure

Three umbrella charts in `helm/`:

- **`helm/common-services/`** (chart: `platform`):
  - `values.yaml` — cluster-wide settings (ingress-nginx, cert-manager, LetsEncrypt issuer).
  - Deploys shared Postgres (3 databases: admin, dpg, aggregator) and Redis.
  - Passwords generated on first install, stored in `data-postgres` / `data-redis` Secrets in `common-services` namespace.

- **`helm/signals/`** (chart: `dpg`):
  - `install.sh` — generates app credentials (`PG_PW`, `REDIS_PW`, `AUTH_SECRET`) into `values.yaml` on first run.
  - `values.yaml` — image tags, app config, connection strings.
  - **Do not commit populated `values.yaml`** — run `make dpg-cleanup` to scrub secrets back to placeholders.

- **`helm/aggregator/`** (chart: `aggregator-dpg`):
  - `values.yaml` — has `change-me-*` placeholders for SMTP, Keycloak, secrets (must be replaced before production).
  - Subcharts `ingress-nginx` and `cert-manager` are disabled (`enabled: false`) since `platform` owns them cluster-wide.
  - Keycloak init Job depends on Postgres readiness.

---

## Key Configuration

### Infrastructure

**Edit only `opentofu/aws/dev/global-values.yaml`**. Notable settings:

```yaml
global:
  building_block: "purple-dots"           # AWS resource naming prefix
  environment: "dev"                      # 1–9 alphanumeric
  cloud_storage_region: "ap-south-1"
  eks_cluster_version: "1.35"
  eks_node_instance_type: "t3.large"      # 2 vCPU / 8 GB
  eks_node_count_min: 1
  eks_node_count_max: 2
  service_account_subjects:               # IRSA principals
    - "system:serviceaccount:aggregator:aggregator-api"
    - "system:serviceaccount:aggregator:aggregator-worker"
```

### Hostnames & DNS

Set in each chart's `values.yaml` (e.g., `helm/aggregator/values.yaml`):
- `global.publicHost` (e.g., `purpledots.servehalflife.com`) → create A/CNAME DNS records pointing at `ingress-nginx` LoadBalancer hostname after `make platform-install`.

### Image Pull Secrets

Private images at `ghcr.io/blue-dots-economy/*` require a pull secret named `ghcr-pull`:

```bash
# Create the secret (once per namespace)
kubectl create secret docker-registry ghcr-pull \
  -n dpg --docker-server=ghcr.io \
  --docker-username=<gh-user> --docker-password=<GHCR_PAT_read:packages>
# repeat for aggregator namespace
```

Helper scripts `helm/signals/rotate-ghcr-pull.sh` and `helm/aggregator/rotate-ghcr-pull.sh` rotate these.

---

## State & Secrets

- **Infrastructure state**: Stored in S3 bucket (encrypted, versioned, private). Never committed; `.terraform/`, `*.tfstate`, `*.tfvars`, and generated `tf.sh` / `global-cloud-values.yaml` are in `.gitignore`.
- **Secrets in Helm charts**: Generated at install time and stored in Kubernetes Secrets. **Never commit populated `values.yaml` files** with real credentials.
  - `make dpg-cleanup` scrubs `helm/signals/values.yaml` passwords back to placeholders.
  - `helm/aggregator/values.yaml` has `change-me-*` stubs that must be replaced before production.

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

In-progress feature branches: `kong-nginx-impl`, `deploy-release-changes`
(`gcp-support` and `otel-monitoring` are already folded into `feature`).

---

## Prerequisites & Tools

| Tool | Purpose | Min Version |
|------|---------|-------------|
| `aws` CLI | credentials, S3 tfstate | v2 |
| `opentofu` | provisioning via terragrunt | 1.6+ |
| `terragrunt` | OpenTofu orchestration | 0.55+ |
| `yq` | parse `global-values.yaml` | mikefarah 4 |
| `kubectl` | cluster communication | matches EKS |
| `helm` | Kubernetes deployments | v3.12+ |
| `openssl`, `sed` | password generation | — |

Also required:
- AWS credentials with VPC, EKS, IAM, S3 create permissions.
- GHCR pull token (`read:packages` scope).
- DNS records pointing public hostnames to the LoadBalancer once it exists.

---

## Inspect & Debug

```bash
# View cluster state
kubectl cluster-info
kubectl -n common-services get pods,svc
kubectl -n dpg get pods,svc,ingress
kubectl -n aggregator get pods,svc,ingress

# View Helm releases
helm list -A

# View generated secrets (e.g., Postgres password)
kubectl -n common-services get secret data-postgres -o yaml

# Follow logs
kubectl -n dpg logs -f deploy/dpg-api
kubectl -n aggregator logs -f deploy/aggregator-web

# Port forward
kubectl -n common-services port-forward svc/platform-postgresql 5432:5432
```

---

## New Environment

To add a new deployment environment (e.g., `staging`):

1. Copy `opentofu/aws/template/` to `opentofu/aws/staging/`.
2. Edit `opentofu/aws/staging/global-values.yaml` with the new environment settings.
3. Run `cd opentofu/aws/staging && ./install.sh`.

---

## Makefile Targets

All targets from repo root:

```bash
make help               # Show all targets
make preflight          # Verify kubectl + helm + cluster reachable
make platform-install   # Install platform (step 1)
make dpg-install        # Install signals/dpg (step 2)
make aggregator-install # Install aggregator (step 3)
make install            # All three in order (step 1→2→3)
make lint               # helm lint all charts
make template           # helm template all (render smoke test)
make dry-run            # helm --dry-run against current cluster
make uninstall          # Reverse: aggregator → dpg → platform
```

---

## Files to Know

- `.gitignore` — ignores state, secrets, credentials, `.terraform/`, `*.tfstate`, `*.tfvars`.
- `Makefile` — Helm orchestrator; defines install order and credential passing.
- `README.md` — detailed project documentation.
- `helm/README.md` — per-chart details and secrets handling.
- `opentofu/aws/dev/global-values.yaml` — single source of truth for cluster configuration.
- `opentofu/aws/_common/*.hcl` — shared Terragrunt/OpenTofu configuration.
