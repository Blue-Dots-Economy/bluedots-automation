# Blue Dots Economy — Deployment Guide

End-to-end guide to stand up the Blue Dots Economy stack on AWS: provision the
cloud infrastructure with OpenTofu/Terragrunt, then deploy the three helm
charts with `install.sh`. There is **no Makefile** — `install.sh` is the single
entrypoint for both infra and helm.

- **Infra**: VPC, EKS, IAM/IRSA, S3, random secrets — `opentofu/aws/<env>/`
- **Apps**: `common-services` → `signals` → `aggregator` helm releases
- **Glue**: the `output-file` tofu module generates one root-level values file
  per chart; `install.sh` feeds each to helm via a single `-f`.

---

## 1. Required tools and versions

Install these locally before starting. Versions below are the **tested**
baseline; equal-or-newer minor versions are generally fine.

| Tool         | Tested version | Minimum   | Purpose                                            |
|--------------|----------------|-----------|----------------------------------------------------|
| `bash`       | 5.2.21         | 4.x       | runs `install.sh`                                  |
| `git`        | 2.43.0         | 2.x       | clone the repo                                     |
| `aws` CLI    | 2.25.8         | 2.x       | AWS auth + STS; EKS kubeconfig                     |
| `tofu`       | 1.11.1         | ≥ 1.6.0   | provisions cloud resources (OpenTofu)             |
| `terragrunt` | 0.96.0         | ≥ 0.90    | wraps tofu; per-unit state + dependency wiring     |
| `kubectl`    | 1.35.3         | ≥ 1.24    | talk to the EKS cluster                            |
| `helm`       | 3.17.2         | ≥ 3.12    | install the charts                                 |

> `yq` is **not** required — per-chart value slicing was removed; the tofu
> module emits root-level files directly.

Verify in one shot:

```bash
bash --version | head -1
git --version
aws --version
tofu version
terragrunt --version
kubectl version --client
helm version --short
```

### Also required

- An **AWS account** with credentials that can create VPC/EKS/IAM/S3 and an S3
  bucket for tofu remote state.
- A **GitHub PAT** with `read:packages` scope (`GHCR_PAT`) — the charts pull
  images from `ghcr.io`.
- **DNS control** for the public host names (set after the LoadBalancer is up —
  see step 7).

---

## 2. Bring up the infrastructure

All commands run from the environment directory. `template/` is the reference
env; clone it for new environments.

```bash
# 0. clone / pick an environment
cd <repo>
cp -R opentofu/aws/template opentofu/aws/dev      # or use template/ directly
cd opentofu/aws/dev
```

```bash
# 1. authenticate to AWS, confirm the identity is live
aws sso login                                     # or export static keys
aws sts get-caller-identity                       # must succeed (no 403)
```

```bash
# 2. review / edit the environment inputs
#    global-values.yaml holds region, EKS sizing, buckets, and the public hosts:
#      signals_host, signals_ui_host, aggregator_host
$EDITOR global-values.yaml

#    tf.sh exports the AWS region + the tofu remote-state bucket name
cat tf.sh
```

There are two ways to bring up the infra. **Option A** is the one-shot
bootstrap; **Option B** runs the same four functions individually, so you can
inspect each step (create the tf backend first, then create the tf resources).
Both run the identical functions in the identical order — pick whichever fits.

#### Option A — one-shot bootstrap (combined)

```bash
# run the full infra bootstrap (no-arg install.sh)
#    chains: create_tf_backend -> backup_configs -> create_tf_resources -> apply_gp3_default_sc
bash install.sh
```

#### Option B — step by step (individual functions)

Each step is one `install.sh` function; pass it by name. Run **in this order** —
`create_tf_backend` writes `tf.sh` (region + state-bucket name) that
`create_tf_resources` sources, so the backend must exist first.

```bash
# 1. create the tofu remote-state S3 bucket (writes tf.sh)
bash install.sh create_tf_backend

# 2. create the tofu resources: source tf.sh + terragrunt run --all apply
#    (VPC -> EKS -> IAM -> storage -> random_passwords -> output-file), writes
#    the EKS kubeconfig, and generates the 3 per-chart values files
bash install.sh create_tf_resources

# 3. make gp3 the cluster-default StorageClass (demote gp2)
bash install.sh apply_gp3_default_sc
```

You can also chain several in one call (same as Option A):
`bash install.sh create_tf_backend backup_configs create_tf_resources apply_gp3_default_sc`.

What the four functions do (run by both options):

1. `create_tf_backend` — creates the S3 state bucket (via `create_tf_backend.sh`)
   and writes `tf.sh` with the region + bucket name.
2. `backup_configs` — backs up any existing `~/.kube/config`, sets `KUBECONFIG`.
3. `create_tf_resources` — `source tf.sh` then `terragrunt run --all apply`
   (VPC → EKS → IAM → storage → random_passwords → output-file), and writes the
   EKS kubeconfig. This also generates the three per-chart values files into the
   env directory.
4. `apply_gp3_default_sc` — makes `gp3` the default StorageClass (demotes `gp2`).

> Regenerate **only** the values files later (e.g. after changing a host in
> `global-values.yaml`):
> ```bash
> source tf.sh
> ( cd output-file && terragrunt apply )
> ```

---

## 3. Validate the infrastructure

```bash
# cluster reachable + correct context
kubectl config current-context            # arn:aws:eks:<region>:<acct>:cluster/<name>
kubectl cluster-info
kubectl get nodes                         # nodes Ready

# gp3 is the default StorageClass (gp2 must NOT be default)
kubectl get sc                            # gp3 (default) ; gp2 (no default marker)

# the three generated per-chart values files exist
ls -l common-services-values.yaml signals-values.yaml aggregator-values.yaml

# hosts were templated from global-values.yaml
grep -E "host:|publicHost:" signals-values.yaml aggregator-values.yaml

# tooling + cluster + files, all in one (install.sh helper)
bash install.sh preflight
```

Expected: context points at the new cluster, nodes `Ready`, `gp3 (default)`,
all three values files present, and `preflight` prints the context + values
paths with no error.

---

## 4. Configure required values before deploying

Some values are **not** auto-generated — you must set them, or services come up
misbranded / unable to send OTP / unable to log in. Two layers:

- **`global-values.yaml`** — edit **before** `terragrunt apply` (these template
  into the generated per-chart files).
- **Generated per-chart files** (`common-services-values.yaml`,
  `signals-values.yaml`, `aggregator-values.yaml`) — edit **after**
  `terragrunt apply` writes them, **before** the helm deploy.
  > ⚠️ Re-running `terragrunt apply` on the `output-file` unit **regenerates and
  > overwrites** these files. Set these after your *final* apply, or bake them
  > into the module `.tfpl` templates so they survive regeneration.

### `global-values.yaml` (public hosts)

| Key | Meaning |
|-----|---------|
| `signals_ui_host` | Signals UI FQDN |
| `aggregator_host` | Aggregator FQDN (templated into aggregator `global.publicHost`) |

(`signals_host` — the Signals API FQDN — also lives here.)

### `signals-values.yaml`

| Path | Value |
|------|-------|
| `ui.runtimeConfig.VITE_GOOGLE_MAPS_API_KEY` | Google Maps JS API key |
| `notification-service.secrets.data.GMAIL_USER` | Sender Gmail address |
| `notification-service.secrets.data.GMAIL_PASS` | 16-char Gmail **App Password** — **strip the display spaces** (16 chars, not 19) |
| `notification-service.secrets.data.MSG91_AUTH_KEY` | MSG91 key (SMS OTP; leave blank if unused) |
| `notification-service.secrets.data.MSG91_TEMPLATE_ID` | MSG91 template id |
| `match-score.configFiles.aiProvidersJson` → `openai.apiKey` | replace `REPLACE_WITH_OPENAI_API_KEY` |

### `aggregator-values.yaml`

| Path | Value |
|------|-------|
| `global.publicHost` | Aggregator FQDN (templated from `aggregator_host`) |
| `global.signalstack.actingOrgId` | network_service org id — **fetched after signals is deployed** (see below) |
| `secrets.smtpUser` | Sender email for SMTP auth |
| `secrets.smtpPassword` | 16-char Gmail App Password — **no spaces** |
| `api.adminEmails` | Admin notification recipient(s) |
| `mail.smtp.from` | From address on outgoing mail |

### `common-services-values.yaml`

No manual values — Postgres/Redis credentials are auto-generated by the
`random_passwords` module.

### `actingOrgId` — fetch it after signals is up

`actingOrgId` only exists once the signals migrate-job has seeded the
`organization` table, so it's a **post-signals** step:

```bash
# 1. deploy signals first (next section), then:
cd opentofu/aws/<env>
ORG_ID=$(./get-signalstack-org-id.sh)        # prints the network_service org id
echo "$ORG_ID"                               # e.g. org_59102d50-...

# 2. set it in aggregator-values.yaml:
#    global:
#      signalstack:
#        actingOrgId: "<ORG_ID>"
# 3. then deploy aggregator.
```

Without it, aggregator login fails with `SIGNALSTACK_ORG_NOT_REGISTERED`.

> The script reads the `dpg-postgres` secret and queries the shared Postgres
> (`SELECT id FROM organization WHERE type='network_service'`). It prints only
> the id (errors to stderr), so capture it or pipe into a `--set`.

---

## 5. Deploy the services — step by step

Deploy in **strict dependency order**: `common-services` first (it owns
ingress-nginx, cert-manager, the shared Postgres + Redis), then `signals`, then
`aggregator`. Gate each step on the previous being healthy.

```bash
# from opentofu/aws/<env>

# 0. GHCR token for image pulls (read:packages)
export GHCR_PAT=ghp_xxxxxxxxxxxxxxxxxxxx

# (optional) static checks — install nothing
bash install.sh lint        # helm lint all 3 charts
bash install.sh dry_run     # helm --dry-run all 3 against the cluster
```

```bash
# 1. namespaces + ghcr-pull secret in each
bash install.sh create_namespaces_and_secrets
#    verify:
kubectl get ns common-services signals aggregator
for ns in common-services signals aggregator; do kubectl -n $ns get secret ghcr-pull; done
```

```bash
# 2. common-services (applies gp3 first, then helm --wait)
bash install.sh deploy_common_services
#    verify Postgres + Redis are Ready and PVCs bound BEFORE moving on:
kubectl -n common-services get pods
kubectl -n common-services get pvc
kubectl get clusterissuer letsencrypt-prod
```

```bash
# 3. signals (connects to common-services Postgres + Redis)
bash install.sh deploy_signals
kubectl -n signals get pods,svc,ingress
```

```bash
# 4. aggregator (Keycloak init job runs after Postgres is Ready — slowest)
bash install.sh deploy_aggregator
kubectl -n aggregator get pods,svc,ingress
```

> Each `deploy_*` runs `helm upgrade --install ... --wait`, so it blocks until
> that release's own pods are Ready. It does **not** verify cross-namespace
> dependencies, so confirm common-services Postgres/Redis are Ready yourself
> before deploying signals/aggregator.

---

## 6. Deploy everything at once (alternative to step 5)

Instead of the four manual steps, one function deploys the whole stack in the
correct order:

```bash
export GHCR_PAT=ghp_xxxxxxxxxxxxxxxxxxxx
bash install.sh deploy_all_services
```

`deploy_all_services` chains:

```
preflight
  → create_namespaces_and_secrets
    → deploy_common_services   (gp3 + common-services)
      → deploy_signals
        → deploy_aggregator
```

Use the step-by-step flow (step 5) when you want to inspect health between
releases; use `deploy_all_services` for a clean, unattended full deploy.

---

## 7. Validate after deployment

```bash
# all three releases deployed
helm list -A                              # common-services, signals, aggregator = deployed

# every pod Running / Ready, no crashloops
kubectl -n common-services get pods
kubectl -n signals          get pods
kubectl -n aggregator       get pods

# services + ingress, and the host names match global-values.yaml
kubectl get ingress -A
#   signals API  -> signals_host
#   signals UI   -> signals_ui_host
#   aggregator   -> aggregator_host

# TLS issuance (cert-manager + Let's Encrypt)
kubectl get clusterissuer letsencrypt-prod
kubectl get certificate -A                # READY=True once ACME completes

# functional smoke test (in-cluster, no DNS needed)
kubectl -n signals run smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  -s -o /dev/null -w "signals-api %{http_code}\n" \
  http://signals-api.signals.svc.cluster.local:2742/
```

Then point DNS (A / CNAME) for `signals_host`, `signals_ui_host`, and
`aggregator_host` at the ingress-nginx LoadBalancer:

```bash
kubectl -n common-services get svc | grep LoadBalancer    # external hostname
```

Once DNS resolves and certs are `READY=True`, the public URLs are live.

---

## 8. Teardown

```bash
# helm releases + namespaces, reverse order (aggregator -> signals -> common-services)
bash install.sh cleanup_all_services
```

> **Destructive.** Deleting the `common-services` namespace deletes its
> Postgres + Redis PVCs (gp3 `reclaimPolicy: Delete`) — the EBS volumes and all
> data are destroyed. Back up first.

Individual: `destroy_aggregator`, `destroy_signals`, `destroy_common_services`.

Tear down the cloud infra too (needs valid AWS creds):

```bash
bash install.sh destroy_tf_resources       # terragrunt run --all destroy
```

---

## install.sh function reference

| Function                        | What it does |
|---------------------------------|--------------|
| *(no args)*                     | Full infra bootstrap: backend → kubeconfig → `terragrunt apply` → gp3 |
| `create_tf_backend`             | Create the S3 remote-state bucket |
| `backup_configs`                | Back up `~/.kube/config`, set `KUBECONFIG` |
| `create_tf_resources`           | `source tf.sh` + `terragrunt run --all apply` + write kubeconfig |
| `apply_gp3_default_sc`          | Make gp3 the default StorageClass (demote gp2) |
| `destroy_tf_resources`          | `terragrunt run --all destroy` |
| `create_namespaces_and_secrets` | Create 3 namespaces + `ghcr-pull` secret in each |
| `deploy_common_services`        | gp3 + helm install common-services |
| `deploy_signals`                | helm install signals |
| `deploy_aggregator`             | helm install aggregator |
| `deploy_all_services`           | preflight → ns/secrets → all 3 in order |
| `destroy_aggregator` / `destroy_signals` / `destroy_common_services` | uninstall release + delete namespace |
| `cleanup_all_services`          | destroy all 3 in reverse order |
| `preflight`                     | check helm/kubectl/cluster + 3 values files |
| `lint`                          | `helm lint` all 3 charts |
| `dry_run`                       | `helm --dry-run` all 3 |

Run any function by name, chain several:
`bash install.sh lint dry_run`.

### Overridable environment variables

`GHCR_PAT` · `CS_VALUES` / `SIGNALS_VALUES` / `AGG_VALUES` (values file paths) ·
`CS_NS` / `SIGNALS_NS` / `AGG_NS` (namespaces) · `CS_REL` / `SIGNALS_REL` /
`AGG_REL` (release names).

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `InvalidClientTokenId` / STS 403 during `terragrunt` | AWS creds expired → `aws sso login` (or refresh keys), confirm with `aws sts get-caller-identity` |
| `Backend configuration changed` | didn't `source tf.sh` (backend bucket unset) → run it first; or `terragrunt init -reconfigure` |
| `preflight`: `values file not found` | run `terragrunt apply` on the `output-file` unit to generate the 3 files |
| `preflight`: `cluster unreachable` | wrong kube-context → check `kubectl config current-context` |
| Pods `ImagePullBackOff` | bad/missing `GHCR_PAT` → re-run `create_namespaces_and_secrets` with a valid PAT |
| PVCs stuck `Pending` | gp3 not default → `bash install.sh apply_gp3_default_sc` |
| Ingress host wrong / two ingresses collide | stale values file → fix host in `global-values.yaml`, regenerate, redeploy the release |
| Namespace stuck `Terminating` | a resource finalizer is wedged — inspect with `kubectl get ns <ns> -o json` |

For chart internals and the values-file/host model, see
[`helm/README.md`](./helm/README.md).
