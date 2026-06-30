# Deployment Architecture

A living, diagram-led view of how the Blue Dots Economy platform is deployed by
this repo (OpenTofu/Terragrunt for infra, Helm for the app stack). Diagrams are
derived from the actual charts and OpenTofu modules — when the infra changes,
update the diagrams and the facts below.

> Source of truth is the code: `opentofu/aws/` and `helm/{common-services,signals,aggregator}/`.
> The diagrams summarise it; they don't replace it.

## The three views

The architecture is sliced into three layered diagrams (Excalidraw — open to
edit/export PNG):

| # | View | What it answers | Link |
|---|------|-----------------|------|
| 1 | **AWS / EKS infrastructure** | VPC, subnets, EKS node group, IAM/IRSA → S3, LoadBalancer, DNS/ACME, image registry | https://excalidraw.com/#json=J2RAnfhW9rTBZPhUEHqgE,1xZgn5XSmMecbgE4NkKZ-A |
| 2 | **Kubernetes namespaces & shared data** | The 3-namespace boundary, shared Postgres (3 DBs) + Redis, which workload uses which DB/secret | https://excalidraw.com/#json=S7GpWORkMzO-vOdfLwC9M,nCyUCj_lZI65vjt44v8MFQ |
| 3 | **Application & traffic flow** | User → ELB → Kong → host+path routes → services, inter-service calls, external deps, deployment variants | https://excalidraw.com/#json=yJM12LnuFm-WXVEVzS6jK,9_3b4JReayH_rKtqiWydIw |

> Excalidraw share links are public-read snapshots. Re-export after edits and
> update the links here, or save the `.excalidraw` files alongside this doc.

---

## 1. AWS / EKS infrastructure

One EKS cluster hosts everything; one ELB fronts it.

- **Region:** `ap-south-1`. **VPC:** `10.0.0.0/16`, public subnets across AZ-a / AZ-b
  (private subnets + NAT are off by default). Source: `opentofu/aws/_common/network.hcl`.
- **EKS:** version `1.35`, managed node group `m6a.large`, 1–2 nodes, 30 GB disk,
  `gp3` default StorageClass. Source: `opentofu/aws/_common/eks.hcl`,
  `opentofu/aws/<env>/global-values.yaml`.
- **IRSA → S3:** the `aggregator-api` and `aggregator-worker` ServiceAccounts assume
  an IAM role (`{building_block}-{env}-app-sa`) via the cluster OIDC provider to read/write
  S3 (public bucket for QR PNGs, private bucket for bulk uploads). Source:
  `opentofu/aws/_common/iam.hcl`, `opentofu/aws/_common/storage.hcl`.
- **Entry + out-of-band:** users → DNS → ELB → Kong; cert-manager solves ACME HTTP-01
  against Let's Encrypt; nodes pull images from GHCR (`ghcr.io/blue-dots-economy/*`).

> Node type note: `m6a.large` lacks AVX-512. pgvector builds that use AVX-512 can
> SIGILL on these nodes — see the project memory on pgvector/m6a if vector inserts crash.

## 2. Kubernetes namespaces & shared data

Three Helm releases, **deployed in strict order** (`make install`): `platform` →
`dpg` (Signals) → `aggregator`. Remember: directory ≠ chart ≠ release ≠ namespace
(see the repo README table).

- **`common-services`** (chart `platform`): Kong ingress (DB-less), cert-manager +
  `letsencrypt-prod`, and the **shared data layer** — one PostgreSQL 17
  (`platform-postgresql:5432`) and one Redis 7 (`platform-redis-master:6379`).
- **Shared Postgres holds 3 databases:** `dpg` (Signals; extensions `pgcrypto`,
  `cube`, `earthdistance`, `vector`, `postgis`), `aggregator`, and `keycloak`.
  Passwords live in the `data-postgres` / `data-redis` Secrets.
- **`dpg`** (chart `dpg` = Signals): `signals-api :2742`, `signals-ui :8080`,
  `notification-svc :3000`, `match-score :3000`, `search api/worker :3100`,
  `TEI embeddings (bge-m3) :80`, plus a post-install schema-migration Job.
- **`aggregator`** (chart `aggregator-dpg`): `aggregator-web` (BFF) `:3000`,
  `aggregator-api :4000`, `aggregator-worker` (headless), `keycloak :8080` (+`:9000`
  mgmt), plus a keycloak-init Job that waits for Postgres.
- Both app namespaces connect to the **same** Postgres/Redis in `common-services`.
  Each app namespace needs its own `ghcr-pull` image pull secret.

## 3. Application & traffic flow

- **Ingress:** Users → ELB `:443` → **Kong** (TLS termination + per-route rate
  limiting backed by the shared Redis). Kong routes by host + path:
  - signals host: `/` → `signals-ui`, `/api` → `signals-api`
  - aggregator host: `/` → `aggregator-web`, `/backend` → `aggregator-api`,
    `/auth` → `keycloak`
- **Inter-service (in-cluster):** `signals-api` → `notification-svc` (HMAC),
  `match-score` (HMAC), `search` → `TEI`; `aggregator-web` → `keycloak` (OIDC) and
  `aggregator-api`; `aggregator-api` → `signals-api` admin API (`X-Api-Key` +
  `x-acting-org-id`).
- **External deps:** `match-score` → OpenAI/Gemini; `notification-svc` → Gmail SMTP;
  `keycloak`/notifications → MSG91 SMS (OTP).

### Deployment variants

- **Default (current):** Kong ingress (DB-less) with Redis-backed rate limiting —
  this is the Phase-5 state of the platform chart. `ingress-nginx` is retired.
- **Per-deployment branches** carry only their own config (hostnames, served
  network — `purple_dot` / `blue_dot` / `yellow_dot` / ..., image tags, node sizing,
  and their own `opentofu/aws/<env>/`). Examples: `blue-dots-dev`, `orange-dots-dev`,
  `orange-dot-prod`. Never deploy a customer env from `main` — use its branch.

---

## Regenerating these diagrams

These were generated from the charts/modules listed above. To refresh: re-read the
current chart values + OpenTofu modules, update the three Excalidraw scenes, re-export,
and replace the links in the table. Keep the three layers (infra / namespaces+data /
app+flow) so each stays readable on its own.
