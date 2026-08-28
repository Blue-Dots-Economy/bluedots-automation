# CLAUDE.md — opentofu (infra provisioning)

Guidance for the OpenTofu/Terragrunt half of the repo. Read the root `CLAUDE.md` first (the install.sh dispatcher, the values-file architecture, the naming table). This file covers the infra layer specifically. `DEPLOYMENT.md` is the authoritative end-to-end runbook + `install.sh` function reference.

## Layout

Everything lives at `opentofu/aws/<env>/`. On trunk branches only `template/` exists — copy it to make an env: `cp -R opentofu/aws/template opentofu/aws/dev && cd opentofu/aws/dev`. Per-deployment branches carry their own `<env>/` directory.

- **`<env>/global-values.yaml`** — the *only* file you edit, and you edit **anchors at the top only** (the "Environment inputs" block: `_building_block`, `_environment`, hosts, `_network`/`_brand`, SMTP/MSG91, EKS sizing, RDS sizing, …). Everything under `global:` references those anchors — don't hunt through the body.
- **`<env>/root.hcl`** — Terragrunt backend/provider generation, derived from `global-values.yaml`.
- **`<env>/tf.sh`** — written by `create_tf_backend` (exports AWS region + tfstate bucket); `create_tf_resources` sources it first.
- **`modules/`** — one dir per module; each has a `terragrunt.hcl` including shared logic from `_common/`, all reading `global-values.yaml`.

## Module provision order

`network → eks → iam → storage → random_passwords → rds → output-file`. Plus: `pritunl` depends on `network`; `bastion` depends on `network` + `eks`.

`bastion`/`pritunl` carry a Terragrunt `exclude` block, so `terragrunt run --all` **skips** them when `bastion_enabled`/`pritunl_enabled` is `false` (both default `true`). The `apply_tf_bastion` / `apply_tf_pritunl` install.sh functions ignore that flag and always run — use them to bring up just the VPN/bastion.

## Network topology (`network` module)

VPC split into **public** and **private** subnets. Public subnets host the IGW and — when `nat_gateway_enabled` (default `true`) — **one NAT gateway per AZ** (HA egress; each private subnet gets its own AZ-local route table). Private subnets are `private-eks-*` (sized for EKS nodes, exposed as `private_eks_subnet_ids`, auto-selected by the EKS module) plus smaller `/28` RDS subnets. `pritunl` lands in a public subnet; `bastion` in a `private-eks-*` subnet.

## EKS node placement & capacity

`eks_node_capacity_type` (anchor `_eks_node_capacity_type`, default `ON_DEMAND`; `SPOT` is a per-pilot-branch cost opt-in — **changing it on a live node group forces replacement**). Nodes run in `private-eks-*` subnets by default; `eks_node_subnet_keys` pins them to specific subnet(s)/AZ. **EBS is AZ-locked**, so a single-node cluster must stay in one AZ.

## Managed Postgres (`rds` module) — the auto-wiring is the non-obvious part

`rds` is opt-in (`rds_*` sizing in `global-values.yaml`). Its SG allows `5432` only from the EKS cluster SG, and it shares the master password with the `random_passwords`-generated secret. **Pointing the charts at RDS is automated, not manual:** the `rds` module's `db_address` flows via `_common/output-file.hcl` → `postgres_host` into the `output-file` module, which — **only when the endpoint is non-empty** — emits `global.dataPlatform.postgresHost`, `api.postgres.host`, and `search.postgres.host` into the generated `global-cloud-values.yaml`. Since that file is layered after `global-values.yaml` via `-f` (see root `CLAUDE.md`'s values-file architecture), the RDS endpoint overrides the in-cluster Postgres default for signals + aggregator; with no RDS endpoint, the overrides are simply omitted and the in-cluster default stands. **Caveat:** app DB roles/databases must still exist on the RDS instance — the wiring points the charts at RDS but doesn't bootstrap the databases.

## `output-file` module — where the generated values come from

`output-file` is what makes `preflight` pass: it generates the two gitignored files (`global-secrets.yaml` = all secrets; `global-cloud-values.yaml` = cloud outputs + computed hosts/origins + the RDS host above). After editing config that feeds them, regenerate just these with `bash install.sh apply_tf_output_file` rather than re-running the whole apply.

### One bucket, one role — the s3-export exporter shares both

The signals `s3-export` CronJob used to get a dedicated pair: a private `signals-export` bucket (a `global.buckets` entry) and a write-only IRSA role `<bb>-<env>-signals-s3-export`, created in the `iam` module *only* when that bucket existed. **Both are gone.** The exporter now writes to the same `public` bucket and assumes the same `app_sa` role as the aggregator api/worker, so `global-cloud-values.yaml` emits the `s3-export` IRSA block unconditionally, right beside `aggregator-api`/`worker`, from `app_sa_role_arn` + `storage_bucket_public`.

Three consequences worth knowing:

- **`service_account_subjects` is now load-bearing for signals, not just the aggregator.** `app_sa`'s trust policy is a single `StringEquals` on `<oidc>:sub` against that list, so `system:serviceaccount:signals:signals-s3-export` **must** be listed or the CronJob gets `AccessDenied` from STS *inside the pod* — a clean `helm upgrade` and a green apply, then a failing job hours later at its first scheduled run. It must also match `s3-export.serviceAccount.name`, which the generated file pins to `signals-s3-export`. **Every per-deployment branch needs this entry added to its own `<env>/global-values.yaml`;** the template carries it, existing env files don't.
- **`storage_bucket_public` is keyed by logical name, not by `type`.** The storage module's output is `try(aws_s3_bucket.this["public"].id, null)` — the bucket whose `global.buckets` *key* is `public`, whatever `type` it declares. An env that sets `public: {type: private}` gets a fully access-blocked bucket despite the name; an env that leaves it `type: public` gets an anonymous `s3:GetObject` allow on `/*`. **Check which one your env is before enabling the exporter** — in the `type: public` case the export NDJSON is world-readable, and `app_sa`'s policy is `Get/Put/Delete/List` on the whole bucket rather than the old `PutObject`-only on one prefix.
- **Removing the bucket entry plans a destroy, and the storage module sets no `force_destroy`.** So `tofu apply` on `storage` fails with `BucketNotEmpty` while any export object remains. Copy anything worth keeping to the public bucket, empty the old bucket, then apply.

## Lifecycle rules (`storage` module) — one config, two rules, and the prefix is load-bearing

S3 allows exactly **one** lifecycle configuration per bucket, so both rules live in a single `aws_s3_bucket_lifecycle_configuration.this`. A second resource aimed at the same bucket would *overwrite* this one, not add to it.

**`campaign-export-expiry`** deletes campaign PII exports under `campaign_export_prefix` (default `campaign-exports/`) after `global.campaignExportExpiryDays` days, so decrypted CSVs aren't retained far longer than the download link. The same knob sets the aggregator's `EXPORT_URL_TTL_SECONDS` (`× 86400`) in `helm/aggregator/templates/configmap-global.yaml`, so file expiry and link expiry can't drift — change it in one place. `EXPORT_URL_TTL_SECONDS` is read by the **worker** (`apps/worker/src/config.ts`), which gets it via `envFrom` on the umbrella global ConfigMap.

**The prefix scoping is the whole safety story.** That bucket is shared: `bulk-uploads/` (raw.csv + errors.csv), `qr/` (registration QR PNGs), and the signals s3-export dump at `<network>/<instance_id>/`. A bucket-wide expiration deletes all of them. `campaign_export_prefix` therefore has a `validation` block rejecting an empty string, because `filter { prefix = "" }` is legal and silently means *the entire bucket*. The prefix must match the worker's key builder — `campaign-exports/<signalstackOrgId>/<jobId>.csv` in `aggregator-dpg` `apps/worker/src/services/campaign-process/index.ts`. **A prefix that matches nothing fails completely silently**: no error, no metric, objects simply never expire. Verify with the probe below rather than assuming.

`noncurrent_version_expiration` is **unconditional**, not gated on `versioning_enabled`. The worker writes a deterministic per-job key, so a retry *overwrites* — which on a versioned bucket leaves a noncurrent version holding the same PII that the current-version rule would never reclaim. It's inert without versioning, and ungated it also covers a bucket versioned outside this module.

**`abort-incomplete-multipart-upload`** is deliberately **bucket-wide** (`abortIncompleteMultipartDays`, default 7). Safe, because aborting an *incomplete* upload can never delete a completed object — only orphaned parts that are billed but unreachable. It must be unscoped: the biggest multipart producers sit outside the export prefix — the signals s3-export CronJob (boto3 multiparts large NDJSON; the retired exporter policy carried `s3:AbortMultipartUpload` for this) and bulk CSV uploads.

Either knob at `0` drops its rule; both at `0` skips the resource, since S3 rejects a lifecycle configuration with no rules.

### Verifying it without waiting a day

Lifecycle is an asynchronous daily sweep, so you cannot watch an object vanish on demand. You *can* get S3 to tell you the computed delete date — `x-amz-expiration` comes back on any object a rule matches:

```bash
aws s3api put-object --bucket <bucket> --key campaign-exports/_probe/probe.csv --body /tmp/probe.csv
aws s3api head-object --bucket <bucket> --key campaign-exports/_probe/probe.csv --query Expiration
#  expiry-date="Fri, 28 Aug 2026 00:00:00 GMT", rule-id="campaign-export-expiry"
aws s3api head-object --bucket <bucket> --key qr/<any>.png --query Expiration    # -> None (control)
aws s3api delete-object --bucket <bucket> --key campaign-exports/_probe/probe.csv
```

Always run the **negative control** too — an object under `qr/`, `bulk-uploads/` and `<network>/` must return `None`. That is what proves the rule is scoped rather than bucket-wide.

**The file always outlives the link.** S3 computes `Days` expiry as creation + N days *rounded up to the next UTC midnight*, then sweeps some time after. Measured on a real object: created 11:00 UTC with a 1-day rule → `expiry-date` of **00:00 UTC two days later, ~37h**, against a 24h link TTL. So `campaignExportExpiryDays` is a retention *floor*, never a precise deletion moment — which is why the aggregator's export email must not claim the file is deleted the instant the link dies (`campaign-process/index.ts`, `renderExportEmail`). That copy lives in `aggregator-dpg` and is a separate fix.

### Hand-entered secrets live in `<env>/secrets.yaml` (the third input file)

Some secrets can neither be committed (they're real credentials) nor generated (`random_passwords` can't invent a Gmail App Password). Those live in **`<env>/secrets.yaml`** — gitignored and operator-owned. Create it once per env by copying the committed **`secrets.example.yaml`** (`cp secrets.example.yaml secrets.yaml`) and filling in the real values. `install.sh` deliberately does **not** manage this file: it only has to exist before the `output-file` module runs, which is the only thing that reads it.

`_common/output-file.hcl` reads it every apply (`fileexists()` guard → `{}` when absent, then per-key `try()` → the placeholder), passes the values as module variables, and the `.tfpl` interpolates them. **That's what makes regeneration safe: `apply_tf_output_file` re-renders `global-secrets.yaml` from the same `secrets.yaml`, so hand-entered values are never lost** — the earlier "re-paste after every regenerate" footgun is gone.

Eight keys. Most are **one per distinct secret**, fanned out to every consumer so per-chart copies can't drift. The two Google keys are the deliberate exception — a Google API key accepts only **one** application restriction (HTTP referrers *or* IP addresses), so the browser key and the server key have to be separate entries to be restrictable at all (`google_maps_api_key` → referrers on the signals hosts; `google_geocoding_api_key` → the env's NAT gateway EIPs, both AZs). They may hold the same value if unrestricted.

| `secrets.yaml` key | Rendered into |
|---|---|
| `smtp_password` | notification-service `GMAIL_PASS`, aggregator `secrets.smtpPassword`, monitoring `alerting.email.smtpAuthPassword` |
| `msg91_auth_key` | notification-service `MSG91_AUTH_KEY`, aggregator `secrets.msg91AuthKey` |
| `msg91_template_id` | notification-service `MSG91_TEMPLATE_ID`, aggregator `keycloak.msg91TemplateId` |
| `google_maps_api_key` | signals `ui.runtimeConfig.VITE_GOOGLE_MAPS_API_KEY` (browser) |
| `google_geocoding_api_key` | signals `api.secrets.data.GOOGLE_GEOCODING_API_KEY` (server) |
| `discord_{critical,warning,info}_webhook` | monitoring `alerting.discord.*Webhook` |

Two gotchas worth keeping: the Discord placeholders stay **URL-shaped** (`https://discord.com/api/webhooks/UPDATE_THIS_VALUE/...`) because Alertmanager validates `webhook_url` as a URL at config load — a bare placeholder bricks the whole alertmanager config when discord is enabled. And the `.gitignore` entry is **path-scoped** (`opentofu/aws/**/secrets.yaml`): a bare `secrets.yaml` pattern would also swallow the charts' committed `helm/**/templates/secrets.yaml`.

Never hand-edit `global-secrets.yaml` — it's regenerated output. Edit `secrets.yaml` and re-run `apply_tf_output_file`. Leaving a key as `UPDATE_THIS_VALUE` is fine for anything the deployment doesn't use (MSG91 with SMS off, Discord when alerting is email-only) — it renders through and only matters to the service that reads it.

## Private-cluster access (`pritunl` + `bastion`, both `*_enabled` default `true`)

Two optional modules that make the cluster reachable without a public EKS endpoint or a public deploy box:

- **`pritunl`** — Pritunl OpenVPN server (Ubuntu 22.04 + MongoDB via cloud-init) in a **public** subnet with an Elastic IP; the single front door routing the VPC CIDR to connected laptops. Its SG opens SSH 22 / OpenVPN 1194 UDP+TCP / web-admin 443 to `pritunl_ingress_cidrs`, which **defaults to `0.0.0.0/0` — restrict it** to office/home CIDRs (this SG gates all downstream cluster access). `t3.small` minimum (MongoDB RAM). It has `lifecycle.ignore_changes` on `associate_public_ip_address` so day-2 SG edits don't recreate it (recreation would wipe the hand-configured Pritunl org/user/server — set up once by hand over SSH).
- **`bastion`** — Amazon-Linux-2023 deploy workstation in a **private** `private-eks-*` subnet, **no public IP**, SG allows SSH from the VPC CIDR only (reachable only after VPN connect). Ships kubectl/helm/aws-cli/k9s/git/yq and pre-runs `aws eks update-kubeconfig` at boot. Mapped into the cluster with `AmazonEKSClusterAdminPolicy` via an EKS access entry (`authentication_mode = API_AND_CONFIG_MAP`). No repo code baked in — `git pull` + deploy from here.

Access is **SSH public key only** (`bastion_authorized_keys`, shared by both hosts; private keys stay with devs, so nothing secret lands in tfstate). Add/remove a key or CIDR in `global-values.yaml` and re-apply `bastion`/`pritunl`. To go fully private-endpoint: set both `eks_endpoint_public_access` and `eks_endpoint_private_access` `true`, verify from the bastion, then flip public access `false`.

## Infra state & secrets

tfstate lives in an S3 bucket (encrypted, versioned, private) — never committed; `.terraform/`, `*.tfstate`, `*.tfvars`, generated `tf.sh`/`global-cloud-values.yaml`/`global-secrets.yaml` are all gitignored. App secrets are generated by `random_passwords` + `output-file` into the gitignored `global-secrets.yaml`; most SMTP/MSG91/maps keys are also set there now (as `UPDATE_THIS_VALUE` placeholders — see the `output-file` module section above), a few remain plain anchors in `global-values.yaml`.

The S3 backend uses **`use_lockfile = true`** (`root.hcl`) — OpenTofu's native S3 conditional-write state lock, so concurrent applies can't corrupt state. No DynamoDB lock table is needed (or created).

The `eks` module encrypts **Kubernetes Secrets at rest** in etcd via a customer-managed KMS key (`aws_kms_key.eks_secrets`, rotation on) wired into the cluster's `encryption_config { resources = ["secrets"] }`. The cluster IAM role gets an inline KMS-usage policy (the AWS-managed `AmazonEKSClusterPolicy` has none). Enabling secrets encryption is **one-way** in EKS — it can't later be removed, and applying this to a live cluster is an in-place update.

## Control-plane log retention (`eks` module)

When `cloudwatch_enabled_log_types` is non-empty, EKS ships control-plane logs to CloudWatch and — if the log group `/aws/eks/<cluster>/cluster` doesn't already exist — **auto-creates it with no retention (logs never expire → unbounded cost)**. To control that, the `eks` module declares the group explicitly (`aws_cloudwatch_log_group.eks`, gated on log types being enabled) and the cluster `depends_on` it, so retention is set by `cloudwatch_log_retention_in_days` (`global-values.yaml`, default `90`; `0` = never expire). The knob only matters when log types are enabled — with none, no group is created.

**Existing clusters:** if EKS already auto-created the group, the first apply fails with "log group already exists". Import it once, then apply:

```bash
cd opentofu/aws/<env>/eks
terragrunt import aws_cloudwatch_log_group.eks '/aws/eks/<building_block>-<environment>-cluster/cluster'
```

New clusters (and clusters that currently have logging disabled) need no import.
