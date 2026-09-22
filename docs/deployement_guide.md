# Blue Dots Economy — Deployment Guide

A practical runbook for operators who did **not** build this stack.

You do not need to know OpenTofu, Terragrunt or Helm. Every command in this guide
goes through a single script, `install.sh`, which wraps all three.

- **Part A — Deploy a new instance.** Zero to a running platform on AWS.
- **Part B — Change a running instance.** The day-to-day job: change a setting,
  a secret, or an infrastructure value, and get it live safely.

> **Golden rule:** you only ever edit **two** files by hand —
> `global-values.yaml` (settings) and `secrets.yaml` (credentials).
> Everything else is generated. Editing a generated file wastes your time: the
> next deploy overwrites it.

---

## Contents

- [What you are deploying](#what-you-are-deploying)
- [Part A — Deploy a new instance](#part-a--deploy-a-new-instance)
  - [A1. Prerequisites](#a1-prerequisites)
  - [A2. Get the code and pick your environment](#a2-get-the-code-and-pick-your-environment)
  - [A3. Fill in `global-values.yaml`](#a3-fill-in-global-valuesyaml)
  - [A4. Fill in `secrets.yaml`](#a4-fill-in-secretsyaml)
  - [A5. Provision the infrastructure](#a5-provision-the-infrastructure)
  - [A6. Connect to the cluster](#a6-connect-to-the-cluster)
  - [A7. Deploy the services](#a7-deploy-the-services)
  - [A8. Set `actingOrgId` (required before aggregator)](#a8-set-actingorgid-required-before-aggregator)
  - [A9. Point DNS at the cluster](#a9-point-dns-at-the-cluster)
  - [A10. Verify](#a10-verify)
- [Part B — Change a running instance](#part-b--change-a-running-instance)
  - [B1. The three kinds of change](#b1-the-three-kinds-of-change)
  - [B2. Worked example — change the SMTP mailbox](#b2-worked-example--change-the-smtp-mailbox)
  - [B3. Change recipes](#b3-change-recipes)
  - [B4. Roll back](#b4-roll-back)
- [Troubleshooting](#troubleshooting)
- [Command reference](#command-reference)

---

## What you are deploying

Five Helm releases on one AWS EKS cluster. They must be deployed **in this
order** — each depends on the one above it.

| # | Release | Namespace | What it is |
|---|---|---|---|
| 1 | `monitoring` | `monitoring` | Prometheus, Grafana, Loki, Alertmanager |
| 2 | `common-services` | `common-services` | Kong ingress, cert-manager (TLS), Redis, and the job that creates the databases |
| 3 | `keycloak` | `common-services` | Shared login/identity for both apps |
| 4 | `signals` | `signals` | Signals app — api, ui, notifications, search |
| 5 | `aggregator` | `aggregator` | Aggregator portal — web, api, worker |

Underneath sits AWS infrastructure created by the same script: a VPC, the EKS
cluster, an RDS PostgreSQL database, an S3 bucket, and IAM roles.

> **Naming.** Everything is named `<building_block>-<environment>-…`. If you set
> `building_block: acme` and `environment: prod`, your cluster is
> `acme-prod-cluster` and your database is `acme-prod-postgres`.

---

# Part A — Deploy a new instance

## A1. Prerequisites

### Tools

Install these locally first. Check each with the command shown.

| Tool | Minimum | Check |
|---|---|---|
| `bash` | 4.x | `bash --version` |
| `git` | 2.x | `git --version` |
| `aws` CLI | v2 | `aws --version` |
| `tofu` (OpenTofu) | **1.10+** | `tofu version` |
| `terragrunt` | 0.90+ | `terragrunt --version` |
| `kubectl` | 1.24+ | `kubectl version --client` |
| `helm` | 3.12+ | `helm version --short` |
| `yq` | v4 | `yq --version` |
| `jq` | 1.6+ | `jq --version` |

> `tofu` **1.10 or newer** is required — the remote-state locking this repo uses
> (`use_lockfile`) does not exist in older versions.

### Access

- **AWS credentials** that can create VPC, EKS, IAM, S3 and RDS resources.
  Confirm they are live: `aws sts get-caller-identity`
- **DNS control** over the hostnames you plan to serve.
- **A GHCR token** (`read:packages`) — only if any container image is private.
- **SMTP credentials** (e.g. a Gmail App Password) for outbound email.

---

## A2. Get the code and pick your environment

```bash
git clone https://github.com/Blue-Dots-Economy/bluedots-automation.git
cd bluedots-automation
```

Every deployment gets its **own directory** under `opentofu/aws/`, created by
copying the template. The directory name is the environment name.

```bash
cp -R opentofu/aws/template opentofu/aws/<env>
cd opentofu/aws/<env>
```

> **Run every command in this guide from that directory.** `install.sh` reads
> the files next to it, so running it from anywhere else will not work.

---

## A3. Fill in `global-values.yaml`

This one file holds all non-secret settings — cluster size, hostnames, email,
feature toggles.

**Only edit the block of anchors at the very top of the file.** They look like
this, and everything further down references them:

```yaml
_building_block: &building_block "acme"          # your org/product slug
_environment:    &environment    "prod"          # dev | stg | prod
_cloud_storage_region: &cloud_storage_region "ap-south-1"
```

The three above decide every AWS resource name, so set them first and do not
change them later.

Then work down the anchor block and set the rest — hostnames, SMTP, network and
brand. Each anchor has a comment above it explaining what it does.

> ⚠️ **`_environment` must be 1–9 lowercase letters/digits**, no hyphens.
> `prod` and `dev2` are fine; `production` and `pre-prod` are rejected.

---

## A4. Fill in `secrets.yaml`

Credentials that cannot be generated — a mail password, a maps API key — live in
a separate file that is **never committed**.

```bash
cp secrets.example.yaml secrets.yaml
```

Open `secrets.yaml` and replace each `UPDATE_THIS_VALUE` you actually need. The
comments say which service uses each one.

> **Leave the ones you don't use as `UPDATE_THIS_VALUE`.** They render through
> harmlessly and only matter to the service that reads them.

> 🔒 `secrets.yaml` is **gitignored, plaintext, and yours alone**. It is not
> encrypted by this repo. Store the real values in your team's password manager
> — if you lose this file, you must re-enter every value by hand.

---

## A5. Provision the infrastructure

Two steps. The first creates an S3 bucket to remember what was built; the second
builds it.

```bash
# 1. create the remote-state bucket (writes tf.sh)
bash install.sh create_tf_backend

# 2. create all AWS resources (20-30 minutes; EKS is the slow part)
bash install.sh create_tf_resources

# 3. make a StorageClass the cluster default (charts bind to whatever is default)
bash install.sh apply_default_sc
```

Before step 2 finishes, read the summary that step 1 printed and confirm the
building block, environment, region and account are what you expect.

> **On a non-AWS Kubernetes platform**, set `STORAGE_CLASS_TYPE` to a class that
> platform already provides before step 3 — `apply_default_sc` can only *create*
> `gp3` (AWS-specific); any other name must already exist:
> `export STORAGE_CLASS_TYPE=<your-class>`.

Step 2 also **generates the two files the deploy needs**:

| Generated file | Contains |
|---|---|
| `global-cloud-values.yaml` | bucket name, database endpoint, IAM role ARNs |
| `global-secrets.yaml` | every password and API key, assembled for the charts |

> **Never edit those two files.** They are rebuilt from
> `global-values.yaml` + `secrets.yaml` every time you run
> `install.sh apply_tf_output_file`.

---

## A6. Connect to the cluster

The script does **not** configure `kubectl` for you. Do it now, or every deploy
command will fail with *cluster unreachable*.

```bash
# cluster name is <building_block>-<environment>-cluster
aws eks update-kubeconfig --name acme-prod-cluster --region ap-south-1

# give your own AWS identity admin rights on the cluster
./grant-cluster-admin.sh

# confirm
kubectl config current-context
kubectl get nodes
```

> ⚠️ **Check the context before every deploy.** If your laptop also has a
> `minikube` or another cluster configured, an unchecked `kubectl` context will
> install the entire platform into the wrong place.

---

## A7. Deploy the services

Run the preflight check first — it verifies tools, cluster reachability and that
the generated files exist:

```bash
bash install.sh preflight
```

Deploy **everything except aggregator** first — aggregator needs one manual
value (next step) that only exists once `signals` is up, so it deploys last on
purpose:

```bash
# if any image is private:
export IMAGES_PUBLIC=false
export GHCR_PAT=ghp_xxxxxxxx

bash install.sh create_namespaces_and_secrets
bash install.sh deploy_monitoring
bash install.sh deploy_common_services
bash install.sh deploy_keycloak
bash install.sh deploy_signals
```

Do not reorder these. `keycloak` needs the database `common-services` creates;
`signals` needs `keycloak`.

---

## A8. Set `actingOrgId` (required before aggregator)

Aggregator will not let anyone log in until this is set — it fails with
`SIGNALSTACK_ORG_NOT_REGISTERED`. It only exists once `signals` has seeded its
database, which is why this step sits between `deploy_signals` and
`deploy_aggregator`.

```bash
# from opentofu/aws/<env>
ORG_ID=$(./get-signalstack-org-id.sh)
echo "$ORG_ID"          # e.g. org_59102d50-...
```

The script queries the shared Postgres for you — in-cluster or RDS, it detects
which one `signals` is pointed at. Set the result in `global-values.yaml`:

```yaml
global:
  signalstack:
    actingOrgId: "<ORG_ID>"
```

Then deploy aggregator:

```bash
bash install.sh deploy_aggregator
```

Finally, work around a known cert-manager issue (#7846) where the
`ClusterIssuer`'s ACME account URI can be left blank, which stalls certificate
issuance:

```bash
bash install.sh fix_acme_issuer_uri
```

Safe to run every time — it's a no-op if the URI is already set.

<details>
<summary>Prefer one command for everything?</summary>

```bash
bash install.sh deploy_all_services
```

This runs all five releases **including aggregator**, back to back, with no
pause for `actingOrgId`, and finishes with `fix_acme_issuer_uri` automatically.
Aggregator will come up healthy but logins will fail until you complete A8
above and then re-run `bash install.sh deploy_aggregator`. Use the step-by-step
flow above if you want `actingOrgId` right the first time.
</details>

---

## A9. Point DNS at the cluster

Get the load balancer address:

```bash
kubectl -n common-services get svc common-services-kong-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Create a **CNAME** for each public hostname in `global-values.yaml` pointing at
that address. TLS certificates are issued automatically once DNS resolves —
Let's Encrypt has to reach your hostname to verify it, so certificates stay
pending until DNS is live.

---

## A10. Verify

```bash
# all five releases deployed
helm list -A

# every pod Running/Ready, nothing restarting
kubectl get pods -A | grep -v Running | grep -v Completed

# TLS issued — READY should be True for each
kubectl get certificate -A

# the app answers
curl -sI https://<your-signals-host>/ | head -1

# aggregator login works (fails with SIGNALSTACK_ORG_NOT_REGISTERED if A8 was skipped)
```

---

# Part B — Change a running instance

## B1. The three kinds of change

**This is the most important section in this guide.** Every change falls into
one of three classes, and the class decides what you re-run. Running the wrong
thing is the usual way a healthy instance breaks.

| | 1. App setting | 2. Secret | 3. Infrastructure |
|---|---|---|---|
| **Examples** | SMTP host/port, rate limits, support email, feature toggles | mail password, MSG91 key, Google Maps key, Discord webhook | VPN allow-list, SSH keys, node size, database size, buckets |
| **You edit** | `global-values.yaml` | `secrets.yaml` | `global-values.yaml` |
| **Then run** | `deploy_<release>` | `apply_tf_output_file` → `deploy_<release>` | `apply_tf_<module>` → `apply_tf_output_file` → `deploy_<release>` |
| **Touches AWS?** | no | no | **yes** |
| **Risk** | low | low | **can replace live resources — always plan first** |

Read it as one rule:

> **Changing a secret means regenerating.** `deploy_*` only ever reads
> `global-secrets.yaml`; it never reads `secrets.yaml`. Editing a secret without
> running `apply_tf_output_file` first changes nothing at all.

For class 3, always look before you leap:

```bash
bash install.sh plan_tf_<module>     # shows what WOULD change; changes nothing
```

If the plan says **destroy** or **replace** on a database, node group or bucket,
stop and get a second pair of eyes.

---

## B2. Worked example — change the SMTP mailbox

A good first example, because it spans two of the three classes: the mailbox
settings are plain config, the password is a secret.

### Step 1 — edit the settings (class 1)

In `global-values.yaml`, in the anchor block near the top:

```yaml
_smtp_host:         &smtp_host         "smtp.gmail.com"
_smtp_port:         &smtp_port         587
_smtp_user:         &smtp_user         "noreply@yourdomain.org"
_smtp_from_display: &smtp_from_display "Blue Dots"
```

### Step 2 — edit the password (class 2)

In `secrets.yaml`:

```yaml
smtp_password: "your-app-password-here"
```

### Step 3 — regenerate

```bash
bash install.sh apply_tf_output_file
```

This rewrites `global-secrets.yaml` from both files. It touches no AWS
resources, so it is quick and safe.

### Step 4 — redeploy the services that send mail

One mailbox, **four** consumers:

| Release | Uses it for |
|---|---|
| `signals` | notification service — user emails |
| `aggregator` | portal emails, campaign exports |
| `keycloak` | login OTP emails |
| `monitoring` | Alertmanager alert emails |

```bash
bash install.sh deploy_signals deploy_aggregator deploy_keycloak deploy_monitoring
```

> You can chain targets in one call, as above.

### Step 5 — verify mail actually sends

Do not assume. Confirm the new value arrived, then confirm a real send.

```bash
# 1. the new values reached the generated file (local, no cluster needed)
grep -A2 'SMTP_USER' global-secrets.yaml
yq '.global.smtp' global-values.yaml 2>/dev/null || grep -A4 '^smtp:' global-values.yaml

# 2. the new address reached the cluster
SEC=$(kubectl -n signals get secret -o name | grep notification | head -1)
kubectl -n signals get "$SEC" -o jsonpath='{.data.SMTP_USER}' | base64 -d; echo

# 3. nothing crashed on the new config
kubectl -n signals get pods
kubectl -n aggregator get pods

# 4. watch the logs while you trigger a real email
#    (e.g. request a login OTP in the UI)
kubectl -n signals logs -l app.kubernetes.io/component=notification-service -f --tail=50
```

> If step 2 finds nothing, list what is there with
> `kubectl -n signals get secrets` — chart resource names include the release
> name, so they differ per environment.

A working send logs an accepted/queued message. Authentication failures show up
as an SMTP `535` or `Invalid login` — that means the password, not the host.

---

## B3. Change recipes

Look up your change, run the commands in order.

### Class 1 — app settings

| Change | Edit in `global-values.yaml` | Then run |
|---|---|---|
| Support email | `support_email` | `deploy_signals deploy_aggregator` |
| Admin emails | `_aggregator_admin_emails` | `deploy_aggregator` |
| API rate limits | `_api_rate_limit_*` | `deploy_signals deploy_aggregator` |
| OTP rate limits | `_otp_rate_limit_*`, `_signals_otp_per_minute` | `deploy_signals deploy_keycloak` |
| Public hostnames | `_signals_public_hosts`, `_aggregator_host` | `apply_tf_output_file` then `deploy_signals deploy_aggregator` |
| Image tags | `global-images.yaml` | the matching `deploy_*` |

### Class 2 — secrets

All of these follow the same shape: edit `secrets.yaml` →
`apply_tf_output_file` → redeploy.

| Secret | Redeploy |
|---|---|
| `smtp_password` | `deploy_signals deploy_aggregator deploy_keycloak deploy_monitoring` |
| `msg91_auth_key`, `msg91_template_id` | `deploy_signals deploy_aggregator` |
| `google_maps_api_key`, `google_geocoding_api_key` | `deploy_signals` |
| `discord_*_webhook` | `deploy_monitoring` |

### Class 3 — infrastructure

| Change | Edit | Then run |
|---|---|---|
| Who can reach the VPN | `pritunl_ingress_cidrs` | `plan_tf_pritunl` → `apply_tf_pritunl` |
| Who can SSH the bastion | `bastion_authorized_keys` | `plan_tf_bastion` → `apply_tf_bastion` |
| S3 buckets / CORS | `buckets`, `cors_*` | `plan_tf_storage` → `apply_tf_storage` → `apply_tf_output_file` → `deploy_aggregator` |
| Database size | `rds_instance_class`, `rds_allocated_storage` | `plan_tf_rds` → `apply_tf_rds` |
| Node count / size | `eks_node_*` | `plan_tf_eks` → `apply_tf_eks` |

> ⚠️ **Changing the node instance type or disk size replaces the whole node
> group.** Pods are rescheduled onto new machines. Do it in a maintenance
> window.

---

## B4. Roll back

Helm keeps a history of every release, so undoing a bad deploy is one command:

```bash
helm -n signals history signals          # find the last good REVISION
helm -n signals rollback signals <N>
```

Then put the source files back to match — revert your edit in
`global-values.yaml` / `secrets.yaml`, and re-run `apply_tf_output_file` if a
secret was involved. Otherwise the next deploy reapplies the change you just
rolled back.

> Infrastructure changes have **no** equivalent one-command undo. That is why
> `plan_tf_*` matters.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| PVCs stuck `Pending` | no default StorageClass | `bash install.sh apply_default_sc` |
| `values file not found` from `preflight` | infra never ran, or you're in the wrong directory | `cd opentofu/aws/<env>` then `bash install.sh create_tf_resources` |
| `cluster unreachable` | kubeconfig not set up | redo [A6](#a6-connect-to-the-cluster) |
| `tf.sh: No such file or directory` | fresh clone — the file is gitignored | `bash install.sh create_tf_backend` (safe to re-run) |
| Your secret edit had no effect | `apply_tf_output_file` not run | run it, then redeploy |
| Pods `ImagePullBackOff` | private images without a token | `export IMAGES_PUBLIC=false GHCR_PAT=…`, re-run `create_namespaces_and_secrets`, redeploy |
| Certificate stuck, not `True` | DNS not pointing at the load balancer yet | finish [A9](#a9-point-dns-at-the-cluster), then `kubectl get challenge -A` |
| Certificate stuck, DNS is correct, `ClusterIssuer` `status.acme.uri` is blank | known cert-manager issue #7846 | `bash install.sh fix_acme_issuer_uri` |
| Pod `Pending`, `volume node affinity conflict` | disk is in a different availability zone from the node | see `opentofu/CLAUDE.md` → EKS node placement |
| `helm upgrade` times out | one pod never became healthy | `kubectl -n <ns> get pods` while it waits — the real error is there, not in the Helm output |
| Emails not arriving | wrong password, or an unredeployed release | [B2 step 5](#step-5--verify-mail-actually-sends) |

---

## Command reference

All commands run from `opentofu/aws/<env>/`.

```bash
# --- infrastructure ---
bash install.sh create_tf_backend        # create the remote-state bucket
bash install.sh create_tf_resources      # create/update all AWS resources
bash install.sh apply_default_sc         # make STORAGE_CLASS_TYPE (default gp3) cluster-default
bash install.sh plan_tf_<module>         # preview one module's changes
bash install.sh apply_tf_<module>        # apply one module
bash install.sh apply_tf_output_file     # regenerate the two generated files
#   <module> = network | eks | iam | storage | random_passwords | rds
#              | output-file | bastion | pritunl

# --- deploy ---
bash install.sh preflight                # check tools, cluster, generated files
bash install.sh deploy_all_services      # all five, in order
bash install.sh deploy_monitoring
bash install.sh deploy_common_services
bash install.sh deploy_keycloak
bash install.sh deploy_signals
bash install.sh deploy_aggregator

# --- checks (no cluster changes) ---
bash install.sh lint                     # validate the charts
bash install.sh dry_run                  # render everything without applying

# --- inspect ---
helm list -A
kubectl get pods -A
kubectl -n common-services get svc common-services-kong-proxy

# --- teardown (reverse deploy order) ---
bash install.sh destroy_aggregator
bash install.sh destroy_signals
bash install.sh destroy_keycloak
bash install.sh destroy_common_services
bash install.sh destroy_monitoring
bash install.sh cleanup_all_services      # all five, reverse order, in one call
bash install.sh destroy_tf_resources      # tear down the AWS infrastructure too
```

Chain targets in one call: `bash install.sh deploy_signals deploy_aggregator`.

> ⚠️ `cleanup_all_services` and `destroy_tf_resources` are **destructive** —
> they delete namespaces (including databases) and AWS resources. Never run
> them against a live instance to "retry" something.

### Overridable environment variables

Set any of these before an `install.sh` command to change its default. Most
operators never need them — they exist for running more than one environment's
worth of overrides from the same shell, or for CI.

| Variable(s) | Overrides |
|---|---|
| `GLOBAL_VALUES`, `GLOBAL_SECRETS`, `GLOBAL_CLOUD_VALUES`, `GLOBAL_IMAGES` | paths to the four values files |
| `CS_NS`, `SIGNALS_NS`, `AGG_NS`, `MON_NS`, `KC_NS` | namespace per release (`KC_NS` defaults to `CS_NS`) |
| `CS_REL`, `SIGNALS_REL`, `AGG_REL`, `MON_REL`, `KC_REL` | Helm release name per release |
| `IMAGES_PUBLIC`, `GHCR_PAT` | private-image pulls — see [A7](#a7-deploy-the-services) |
| `EXTRA_HELM_ARGS` | extra flags appended to every `helm upgrade --install` |
| `STORAGE_CLASS_TYPE` | which StorageClass `apply_default_sc` makes cluster-default (default `gp3`) — set this on a non-AWS platform, see [A5](#a5-provision-the-infrastructure) |
| `SIGNALS_DPG_REPO` / `SIGNALS_DPG_REF`, `AGGREGATOR_DPG_REF` | which branch/ref of the schemas repos `fetch_signals_configs` / `fetch_aggregator_configs` pull from — pin these for a reproducible prod deploy |

---

## Where to go next

| Document | Covers |
|---|---|
| [`docs/instance-setup.md`](instance-setup.md) | Launching a new **network or brand** (network.json, consent, branding) |
| [`CLAUDE.md`](../CLAUDE.md) | Architecture: charts, deploy order, how the values files layer |
| [`opentofu/CLAUDE.md`](../opentofu/CLAUDE.md) | Infrastructure detail: VPC, EKS, RDS, VPN, bastion |
| [`helm/CLAUDE.md`](../helm/CLAUDE.md) | Chart detail: Kong ingress, Keycloak realm, certificates |
