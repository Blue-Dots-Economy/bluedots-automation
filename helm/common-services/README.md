# common-services (chart `platform`)

Shared, cluster-wide platform stack. **Install once per cluster, before any app
chart** (signals, aggregator) — they attach to the ingress, issuer, Postgres and
Redis this chart owns.

> Directory `common-services` · chart `name: platform` · release
> `common-services` · namespace `common-services`.

## What it deploys

| Component | Purpose | Subchart |
|-----------|---------|----------|
| **Kong** (DB-less) | ingress controller + cluster-default `IngressClass kong`; rate limiting via `KongClusterPlugin` | `kong` 3.2.0 |
| `cert-manager` | TLS cert issuance (+ CRDs) | `cert-manager` v1.20.2 |
| `letsencrypt-prod` ClusterIssuer | Let's Encrypt production ACME (HTTP-01) | template in this chart |
| **Postgres** | shared DB (admin + `dpg` + `aggregator` databases) | `postgresql` 18.6.6 |
| **Redis** | shared cache / rate-limit counters | `redis` 19.6.4 |
| `metrics-server` | resource metrics for HPA / `kubectl top` | `metrics-server` 3.12.1 |

`ingress-nginx` 4.15.1 is also vendored but **disabled** (`ingress-nginx.enabled:
false`) — Kong is the active controller. When RDS is provisioned the in-cluster
`postgresql` subchart is disabled and the charts point at the RDS endpoint
(wired automatically via `global-cloud-values.yaml`).

## Prerequisites

- `kubectl` current-context pointed at the target cluster, `helm` v3.12+.
- The generated values files exist in the env dir: `global-secrets.yaml` +
  `global-cloud-values.yaml` (run `bash install.sh create_tf_resources` first).
- `gp3` must be the default StorageClass (Postgres/Redis PVCs bind to it) — the
  deploy step applies it for you.
- Kong CRDs must be applied — the deploy step applies them for you (Helm does
  **not** install subchart CRDs, nor update CRDs on upgrade).

## Deploy this chart only

**Recommended — via `install.sh`** (applies gp3 + Kong CRDs, then helm):

```bash
cd opentofu/aws/<env>          # e.g. opentofu/aws/dev
bash install.sh deploy_common_services
```

That runs, from the repo root, exactly:

```bash
ENV=opentofu/aws/<env>

# 1. gp3 as default StorageClass (demote gp2)
kubectl apply -f "$ENV/gp3-sc.yaml"

# 2. Kong CRDs — server-side, idempotent (helm skips subchart/upgrade CRDs)
kubectl apply --server-side -f helm/common-services/crds/

# 3. the chart, with the layered values files (-f order = precedence)
helm upgrade --install common-services helm/common-services \
  -n common-services --create-namespace \
  -f helm/global-resources.yaml \
  -f "$ENV/global-images.yaml" \
  -f "$ENV/global-values.yaml" \
  -f "$ENV/global-cloud-values.yaml" \
  -f "$ENV/global-secrets.yaml" \
  --wait --timeout 5m
```

Wait for Postgres + Redis to be Ready and PVCs Bound **before** deploying
signals/aggregator:

```bash
kubectl -n common-services get pods,pvc
kubectl get clusterissuer letsencrypt-prod          # READY=True
kubectl -n common-services get svc common-services-kong-proxy   # external LB hostname for DNS
```

> **cert-manager ACME (v1.20.2) gotcha.** If certificates stay `READY=False`,
> run `bash install.sh fix_acme_issuer_uri` (also run automatically at the end of
> `deploy_all_services`) — it patches `status.acme.uri` and clears poisoned cert
> chains.

## App-chart wiring

App charts reference common-services-owned resources by name:

- `ingressClassName: kong` on Ingress objects
- `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation for TLS
- `konghq.com/plugins: <rl-auth|rl-api|rl-public>` to attach a rate-limit tier
- Postgres at `common-services-postgresql.common-services.svc` (or the RDS host),
  Redis at `common-services-redis-master.common-services.svc`

The aggregator chart vendors `ingress-nginx`/`cert-manager` subcharts but
disables them (`enabled: false`) so this chart owns them cluster-wide.

## Configuration knobs

Defaults live in `values.yaml`; per-env overrides come from the layered files
above. Common edits:

- `kong` — controller service annotations (cloud LB type), rate-limit
  `KongClusterPlugin` tiers (`rl-auth` / `rl-api` / `rl-public`, backed by Redis).
- `issuer.acmeEmail` / `issuer.server` — Let's Encrypt registration email;
  switch `server` to the staging directory while debugging to avoid rate limits.
- `postgresql` / `redis` — sizing, PVC size, `initdb` extensions.

## Uninstall

```bash
cd opentofu/aws/<env>
bash install.sh destroy_common_services
```

This uninstalls the release, deletes the namespace (**destroys the Postgres +
Redis PVCs / EBS volumes — back up first**), and runs
`cleanup_cert_manager_leftovers` (cert-manager CRDs + the ClusterIssuer carry a
"keep" policy and survive `helm uninstall`, otherwise bricking the next install).
