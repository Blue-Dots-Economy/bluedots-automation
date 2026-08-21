# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**bluedots-automation** is the infrastructure-as-code and deployment system for the Blue Dots Economy platform. It does two things:

1. **Provisions AWS EKS infrastructure** using OpenTofu + Terragrunt (`opentofu/aws/`).
2. **Deploys the application stack** to Kubernetes using Helm (`helm/`).

Both are driven by a **single `install.sh`** in the per-environment directory (`opentofu/aws/<env>/install.sh`). See [DEPLOYMENT.md](DEPLOYMENT.md) for the end-to-end runbook.

> ⚠️ **There is no Makefile.** Older docs referenced `make install` / `make platform-install`; those targets are gone — `install.sh` is the only entrypoint. Treat any `make ...` in stray READMEs/comments as stale. **install.sh and DEPLOYMENT.md are the source of truth.**

**Subsystem docs** (auto-load when you work in that tree — read before making changes there):
- **`opentofu/CLAUDE.md`** — Terragrunt module structure, provision order, network topology, EKS placement/capacity, RDS auto-wiring, private-cluster access (Pritunl + bastion), infra state.
- **`helm/CLAUDE.md`** — Kong ingress + CRD gotcha, cert-manager ACME workaround, actingOrgId step, consent-config ConfigMap delivery, org-hierarchy flag, chart structure, image pull secrets.
- **`.claude/rules/pr-gate.md`** — the develop-PR docs/release-notes gate (path-scoped to `.github/**`).

---

## ⚠️ CRITICAL: Directory vs Chart vs Release vs Namespace

Release name and namespace **match the directory name**. Only the Helm **chart name** (`name:` in `Chart.yaml`) differs — and it differs for every app chart. So when `helm list`, logs, or templates say **`dpg`**, that's the **Signals** chart in `helm/signals/`.

| Directory              | Chart `name`     | Release           | Namespace         | Purpose |
|------------------------|------------------|-------------------|-------------------|---------|
| `helm/monitoring/`     | `monitoring`     | `monitoring`      | `monitoring`      | Prometheus + Alertmanager + Loki + Alloy + Jaeger + Grafana |
| `helm/common-services/`| `platform`       | `common-services` | `common-services` | Cluster-wide: **Kong** ingress, cert-manager, shared Postgres (org **portable-pgvector** image, #93), Redis, metrics-server |
| `helm/keycloak/`       | `keycloak-platform` | `keycloak`     | **`common-services`** | **Shared Keycloak — one realm holding BOTH DPGs' clients.** The one place release name ≠ namespace: it is a common service, so it lives in the common-services namespace. |
| `helm/signals/`        | `dpg`            | `signals`         | `signals`         | Signals stack (api, ui, notification-service, search, **s3-export** non-PII export CronJob) |
| `helm/aggregator/`     | `aggregator-dpg` | `aggregator`      | `aggregator`      | Aggregator portal (web/BFF, api, worker) — Keycloak moved to its own release |

Namespaces / releases / values-file paths are overridable via env vars (`CS_NS`, `SIGNALS_NS`, `CS_REL`, `GLOBAL_VALUES`, …) — see the function reference in DEPLOYMENT.md.

---

## Deploy Order (STRICT)

`deploy_all_services` runs charts in this order; **common-services → keycloak → signals → aggregator** is mandatory:

1. **`monitoring`** — first so metrics/alerts are live from the start (its `kube-prometheus-stack` also ships the ServiceMonitor/PodMonitor/PrometheusRule CRDs others rely on). Functionally optional but deployed first by default.
2. **`common-services`** — owns the Kong ingress controller, cert-manager + `letsencrypt-prod` ClusterIssuer, and shared Postgres/Redis. Without it, other Ingresses sit Pending and ACME challenges fail.
3. **`keycloak`** — the shared realm for both DPGs. **Must be its own release, not a subchart of `common-services`.** The `keycloak` database is created by common-services' `postgres-bootstrap-job`, a **post-install hook**; Helm with `--wait` waits for main resources to be Ready *before* running post-install hooks, so a Keycloak Deployment inside that release would crash-loop on the missing database while the hook that creates it never runs — the release deadlocks and times out. Keeping it a later release means the database already exists. Do not "simplify" this back in.
4. **`signals`** — connects to the shared DBs in `common-services`. Its api asserts Keycloak config at boot once `AUTH_PROVIDER=keycloak`, hence keycloak first.
5. **`aggregator`** — same shared DBs; needs the `actingOrgId` manual step after signals — see `helm/CLAUDE.md`.

Each `deploy_*` runs `helm upgrade --install … --wait`, so it blocks on its own pods but does **not** verify cross-namespace deps — confirm common-services Postgres/Redis are Ready before deploying signals/aggregator.

---

## Common Commands

All commands run from the **environment directory** (`opentofu/aws/<env>/`). On trunk branches only `template/` exists — copy it: `cp -R opentofu/aws/template opentofu/aws/dev && cd opentofu/aws/dev`.

### Infrastructure (OpenTofu/Terragrunt)

```bash
bash install.sh                          # full bootstrap: create_tf_backend → create_tf_resources → apply_gp3_default_sc
bash install.sh create_tf_backend        # create S3 tfstate bucket, write tf.sh
bash install.sh create_tf_resources      # source tf.sh + terragrunt run --all apply + write kubeconfig
bash install.sh apply_gp3_default_sc      # make gp3 the default StorageClass (demote gp2)
bash install.sh destroy_tf_resources     # terragrunt run --all destroy
bash install.sh plan_tf_eks              # plan/apply one module (network|eks|iam|storage|random_passwords|rds|output-file|bastion|pritunl)
bash install.sh apply_tf_output_file     # regenerate just the generated values files
bash install.sh apply_tf_pritunl         # bring up just the VPN host (ignores pritunl_enabled)
bash install.sh apply_tf_bastion         # bring up just the bastion (ignores bastion_enabled)
```

### Application Deployment (Helm)

```bash
# images are public by default; for private ones:
export IMAGES_PUBLIC=false                # and export GHCR_PAT=ghp_xxx
bash install.sh deploy_all_services       # preflight → ns+secrets → monitoring → common-services → keycloak → signals → aggregator → fix_acme_issuer_uri
bash install.sh create_namespaces_and_secrets   # namespaces + ghcr-pull secret in each
bash install.sh deploy_monitoring
bash install.sh deploy_common_services    # applies gp3 + Kong CRDs first, then helm --wait
bash install.sh deploy_keycloak           # shared realm, into the common-services ns
bash install.sh deploy_signals
bash install.sh deploy_aggregator
bash install.sh cleanup_all_services      # DESTRUCTIVE: deletes namespaces incl. Postgres/Redis PVCs

# Static checks (no cluster needed for lint)
bash install.sh lint                      # realm assertions + helm lint all 5 charts
bash install.sh dry_run                   # helm --dry-run all 5 against current cluster (runs preflight first)
bash install.sh preflight                 # verify helm + kubectl + cluster + generated values files exist
```

Chain functions in one call: `bash install.sh lint dry_run`.

---

## Values-File Architecture (the seam between infra and deploy)

Config is **never injected into chart `values.yaml`**. Each `helm upgrade` layers files via repeated `-f` (later wins). Keys sit at **root level keyed by chart** (`api:`, `ui:`, `aggregator-api:`, `alerting:`), so a single `-f` feeds Helm directly — no `yq` slicing (which is why `preflight` no longer needs `yq`).

| File | Source | Committed? | Holds |
|------|--------|-----------|-------|
| chart `values.yaml` | in repo | yes | chart defaults / structure |
| `helm/global-resources.yaml` | in repo, **shared across all envs** | yes | replica counts, HPA, PDB, container resources |
| `<env>/global-images.yaml` | in repo, **per-env** | yes | image `repository` / `tag` / `pullPolicy` |
| `<env>/global-values.yaml` | in repo, **per-env, user-edited** | yes | non-secret config: hosts, network/brand, SMTP, MSG91, DB sizing, app config (edit **anchors at the top only**) |
| `<env>/global-secrets.yaml` | **generated** by `output-file` module | **no** (gitignored) | all secrets (PG/Redis/auth passwords) |
| `<env>/global-cloud-values.yaml` | **generated** by `output-file` module | **no** (gitignored) | cloud outputs + computed hosts/origins + **RDS Postgres host** (when provisioned) |

`preflight` fails if the two generated files are missing → run `bash install.sh create_tf_resources` (or `terragrunt run --all apply`) first. After editing config that feeds them, regenerate only them with `bash install.sh apply_tf_output_file`. How the RDS host lands in `global-cloud-values.yaml` is in `opentofu/CLAUDE.md`.

---

## Branch Strategy

Two kinds: **trunk** branches that integrate work, and **per-deployment** branches that hold one deployment's config.

**Trunk (promotion chain):** `<your-feature-branch>` → `feature` → `develop` → `main`. `main` is canonical (cut new deployment branches from here); `develop` is pre-release integration; `feature` collects in-progress work (usually the newest — check it for the latest unreleased changes).

**Per-deployment branches:** each live deployment has its own long-lived branch (from trunk), carrying only that deployment's config — network JSON schemas, image tags, public hostnames, its own `opentofu/aws/<env>/`. **Never deploy a customer environment from `main`; use its branch.** The set drifts over time — treat `git ls-remote --heads origin` as the source of truth, not a hardcoded list here. As of 2026-07 the prod/live deployment branches are `blue-dots-prod`, `orange-dot-prod`, and `private-cluster` (`purple-dots-prod`, on the old `helmcharts/` layout, has been retired from the remote).

## Authoring pull requests

When you open a PR, include an **In Plain Terms** section in the description: a short, jargon-free explanation a non-expert teammate can follow — what the problem was and what the change does, in everyday language — alongside the usual Summary / Release Notes. Skip it only for a pure chore with no behavioural effect. This lives here as a Claude authoring rule rather than in the GitHub PR template on purpose, so PRs opened from other tools/flows aren't forced through it. (The `develop-pr-gate` still enforces only Release Notes + a `README.md`/`CLAUDE.md` update — see `.claude/rules/pr-gate.md`.)

---

## Prerequisites

| Tool | Purpose | Min Version |
|------|---------|-------------|
| `aws` CLI | credentials, S3 tfstate | v2 |
| `tofu` (OpenTofu) | provisioning via terragrunt | 1.6+ |
| `terragrunt` | OpenTofu orchestration | 0.90+ |
| `kubectl` | cluster communication | ≥ 1.24 |
| `helm` | Kubernetes deployments | v3.12+ |
| `bash` | runs `install.sh` | 4.x+ |

`yq` is **no longer required** (per-chart value slicing was removed). Also need: AWS creds with VPC/EKS/IAM/S3 rights; a GHCR `read:packages` token (`GHCR_PAT`) only if an image is private, with `IMAGES_PUBLIC=false` (default `true` = no pull secret); DNS control to point public hosts at the Kong proxy LoadBalancer (`kubectl -n common-services get svc common-services-kong-proxy`).

---

## CI

`.github/workflows/ci.yml` runs static checks on PRs (and develop/main pushes) that touch `helm/**` or `opentofu/**` — no cluster or cloud creds:

- **helm job** — `scripts/assert-realm.sh` (shared-realm invariants), `helm lint` on all five charts, plus `helm template` render smoke-test on monitoring/common-services/keycloak/aggregator. `signals` is lint-only in CI because its `helm template` needs the network schema files `install.sh` fetches at deploy time (`fetch_signals_configs`), which aren't committed.
- **tofu job** — a blocking `tofu fmt -check -recursive` plus `tofu validate` (with `-backend=false`, provider plugins cached) on every module in `opentofu/aws/modules/*`. Keep the tree `tofu fmt`-clean or the job fails.

The helm job also runs a **DHI mirror drift check**: it renders monitoring + common-services and fails if any `ghcr.io/blue-dots-economy/dhi/*` ref is missing from `.github/dhi-mirror-images.txt`. That combination is an ImagePullBackOff at deploy time whose error text (`denied`) reads like a credentials problem, so it's worth catching in the PR.

This mirrors `bash install.sh lint` but gates it per-PR. Separately, `.github/workflows/develop-pr-gate.yml` enforces the Release-Notes + doc-update PR gate (see `.claude/rules/pr-gate.md`).

---

## Inspect & Debug

```bash
kubectl get sc                                  # gp3 (default); gp2 not default
kubectl -n common-services get pods,svc,pvc
kubectl -n signals get pods,svc,ingress
kubectl -n aggregator get pods,svc,ingress
helm list -A                                    # monitoring, common-services, signals, aggregator
kubectl get clusterissuer letsencrypt-prod
kubectl get certificate -A                      # READY=True once ACME completes
kubectl get challenge -A                        # if stuck, see cert-manager ACME workaround in helm/CLAUDE.md
kubectl -n common-services get secret data-postgres -o yaml
```

See [DEPLOYMENT.md → Troubleshooting](DEPLOYMENT.md) for the symptom→fix table.

---

## New Environment

1. Copy `opentofu/aws/template/` to `opentofu/aws/<env>/` (env name = directory basename, read by `install.sh`).
2. Edit `opentofu/aws/<env>/global-values.yaml` (anchors at the top).
3. `cd opentofu/aws/<env> && bash install.sh` (infra), then `bash install.sh deploy_all_services` (apps).

For a full new-instance / new-network launch (network.json, brand assets, terms & policies, domains, auth channels), follow [docs/instance-setup.md](docs/instance-setup.md).

---

## Files to Know

- `DEPLOYMENT.md` — authoritative end-to-end runbook + `install.sh` function reference + troubleshooting.
- `docs/instance-setup.md` — per-instance checklist for a new environment / network / brand.
- `opentofu/aws/<env>/install.sh` — single entrypoint for infra **and** Helm deploy (function dispatcher).
- `opentofu/aws/<env>/global-values.yaml` — single source of truth for cluster + app config (edit anchors only).
- `helm/global-resources.yaml` — shared replica/HPA/PDB/resource overrides across all envs.
- `scripts/build-realm.sh` — builds the shared deployment realm from an app repo's local-dev realm (applies the production-hardening transform). `scripts/assert-realm.sh` — the invariants CI enforces on it.
- `dockerfiles/` — the **shared base images** this repo builds, one directory each, both **manual `workflow_dispatch` only** (never on push/PR: rarely-rebuilt base images, deliberately outside app CI/CD). Rationale lives in each `Dockerfile` header; pin the resulting tag in `<env>/global-images.yaml`.
  - `dockerfiles/postgres/` → `ghcr.io/<owner>/postgres-pgvector` — Bitnami PG 17 + portable pgvector (the AVX-512 `SIGILL` fix). Workflow: *Build Postgres pgvector image*.
  - `dockerfiles/keycloak/` → `ghcr.io/<owner>/keycloak-server` — upstream Keycloak + the **OTP authenticator SPI**, `kc.sh build`-indexed at image build time so pods boot `start --optimized`. Workflow: *Build Keycloak image*. **Do not drop the jar:** the shared realm's browser flows bind to provider ids that exist only when it loads (`otp-identifier-form`, `otp-channel-choice-form`), so realm import *and* the entitlement-gate Job fail on unknown provider ids rather than quietly degrading to password login. Jar provenance + bump steps: `dockerfiles/keycloak/providers/README.md`.
- `.github/dhi-mirror-images.txt` + `.github/workflows/mirror-dhi-images.yml` — the **third-party** Docker Hardened Images (cert-manager, metrics-server, the whole monitoring stack) copied byte-for-byte from `dhi.io` into `ghcr.io/<owner>/dhi/*`, because dhi.io refuses anonymous pulls and those charts have the *kubelet* do the pull. Distinct from `dockerfiles/` above, which **builds** images: this only **copies** them, digests unchanged, via `regctl image copy --referrers --digest-tags` so the SBOM/provenance/signature travel too. Our own service images need none of this — they are built *from* a DHI base in each app repo's CI. Pinned in `helm/common-services/values.yaml` and `helm/monitoring/values.yaml`, **not** in `<env>/global-images.yaml`. DHI publishes **only current versions**, so the charts were bumped to match the images rather than the reverse (kube-prometheus-stack 65.1.1→88.5.2, loki 6.7.1→7.3.0, alloy 1.8.2→1.11.1, metrics-server 3.12.1→3.14.0) — pinning a DHI image into a chart built for an older app version is what produced the kube-state-metrics readiness failure. Adding an image here without adding it to the mirror list is caught by CI; a chart bump silently changing a rendered tag (88.5.2 turns on node-exporter's `distroless` suffix) is caught by the same check.
- **Keycloak image ownership:** the *server* image is built here (it is network-agnostic and serves both DPGs). The *theme* init image stays in `aggregator-dpg` (`infra/keycloak/build-theme-image.sh`, `keycloak-theme-build.yaml`) because its brand strings come from that repo's `config/<network>[/<brand>]/keycloak.env`. Both are wired in `<env>/global-images.yaml` under `keycloak:`. The app repos still keep their own `infra/keycloak/providers/` jar copy for **local dev only** (stock image + bind-mount + `start-dev`) — those trees are developer-local and not upstream of `dockerfiles/keycloak/`, the same relationship `scripts/build-realm.sh` documents for the realm JSON.
- `opentofu/CLAUDE.md`, `helm/CLAUDE.md` — subsystem detail for the two halves.
- `README.md` / `helm/README.md` / per-chart `helm/*/README.md` — overview + per-chart standalone deploy instructions.
