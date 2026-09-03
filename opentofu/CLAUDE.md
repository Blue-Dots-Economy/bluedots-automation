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

## Generated service api keys (`random_passwords` → `output-file`)

Three secrets in `global-secrets.yaml` are **raw better-auth api keys** rather than passwords or OIDC client secrets: `signalstack_admin_key` (rendered as `AGGREGATOR_DPG_API_KEY`), `signals_search_api_key`, and `raya_voice_bot_api_key`. They share a shape — `random_password`, `special = false`, length from a `*_api_key_length` knob defaulting to **48** with a **`>= 32` validation** — because the signals api migrate-job's `provision_service_users.sql` rejects anything shorter. Only the `base64url(sha256())` hash is ever stored in the database; see `helm/CLAUDE.md` → *Service apikeys* for the consuming side.

The length knobs read through `try(local.global_vars.global.<name>, 48)` in `_common/random_passwords.hcl`, so they are **optional** in `global-values.yaml` — a new key needs no per-env edit. Adding one touches eight files and the pairing that bites is `modules/output-file/main.tf` ↔ `global-secrets.yaml.tfpl`: `templatefile()` renders at **apply** time, so a key referenced in the template but missing from the map passes `tofu validate` and CI, then fails only during `apply_tf_output_file`. Also add a `mock_outputs` entry in `_common/output-file.hcl` (`>= 32` chars, or a plan against empty state trips the SQL length guard).

Do not conflate these with the `voice_dpg_signals_secret` / `*_client_secret` family — those are `random_id` hex Keycloak client secrets for a different auth path. `raya_voice_bot_api_key` and `voice_dpg_signals_secret` belong to the *same* voice bot on purpose and must stay separately rotatable.

## `output-file` module — where the generated values come from

`output-file` is what makes `preflight` pass: it generates the two gitignored files (`global-secrets.yaml` = all secrets; `global-cloud-values.yaml` = cloud outputs + computed hosts/origins + the RDS host above). After editing config that feeds them, regenerate just these with `bash install.sh apply_tf_output_file` rather than re-running the whole apply.

### One bucket, one role — the s3-export exporter shares both

The signals `s3-export` CronJob used to get a dedicated pair: a private `signals-export` bucket (a `global.buckets` entry) and a write-only IRSA role `<bb>-<env>-signals-s3-export`, created in the `iam` module *only* when that bucket existed. **Both are gone.** The exporter now writes to the same `public` bucket and assumes the same `app_sa` role as the aggregator api/worker, so `global-cloud-values.yaml` emits the `s3-export` IRSA block unconditionally, right beside `aggregator-api`/`worker`, from `app_sa_role_arn` + `storage_bucket_public`.

Three consequences worth knowing:

- **`service_account_subjects` is now load-bearing for signals, not just the aggregator.** `app_sa`'s trust policy is a single `StringEquals` on `<oidc>:sub` against that list, so `system:serviceaccount:signals:signals-s3-export` **must** be listed or the CronJob gets `AccessDenied` from STS *inside the pod* — a clean `helm upgrade` and a green apply, then a failing job hours later at its first scheduled run. It must also match `s3-export.serviceAccount.name`, which the generated file pins to `signals-s3-export`. **Every per-deployment branch needs this entry added to its own `<env>/global-values.yaml`;** the template carries it, existing env files don't.
- **`storage_bucket_public` is keyed by logical name, not by `type`** — and which name is `global.app_bucket_key` (default `"public"`). Three separate things, easy to conflate: the map **key** is the bucket's NAME suffix (`<bb>-<env>-<account>-<key>`), **`type`** is the access control, and **`app_bucket_key`** picks which entry becomes `global.s3.bucket` + the `app_sa` policy ARN. So `public: {type: private}` is a fully access-blocked bucket that happens to be *named* `-public`; `app_bucket_key: private` with `private: {type: private}` is the same thing named `-private`. **Check `type` before enabling the exporter** — with `type: public` the export NDJSON is world-readable, and `app_sa`'s policy is `Get/Put/Delete/List` on the whole bucket rather than the old `PutObject`-only on one prefix.
- **`app_bucket_key` must name a real entry, and the module now enforces it at plan time.** It previously resolved with `try(..., null)`; a key that matched nothing became `null`, which `_common/output-file.hcl` turns into `""`, which renders an **empty** `global.s3.bucket`. No chart guards that value — `S3_BUCKET: {{ .Values.global.s3.bucket | quote }}` — so the aggregator installs green, every pod reports healthy, and the first bulk upload / QR render / error-CSV download fails at runtime hours later. An output `precondition` now fails the plan instead, naming the available keys. Renaming the key without updating `app_bucket_key` is exactly how an environment lands in that state.
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

Nine keys. Most are **one per distinct secret**, fanned out to every consumer so per-chart copies can't drift. The two Google keys are the deliberate exception — a Google API key accepts only **one** application restriction (HTTP referrers *or* IP addresses), so the browser key and the server key have to be separate entries to be restrictable at all (`google_maps_api_key` → referrers on the signals hosts; `google_geocoding_api_key` → the env's NAT gateway EIPs, both AZs). They may hold the same value if unrestricted.

| `secrets.yaml` key | Rendered into |
|---|---|
| `smtp_password` | notification-service `GMAIL_PASS`, aggregator `secrets.smtpPassword`, monitoring `alerting.email.smtpAuthPassword` |
| `raya_api_key` | aggregator `secrets.rayaApiKey` — the **outbound** worker→Raya voice key. Not the generated `raya_voice_bot_api_key` (inbound, raya→signals api) and not `voice_dpg_signals_secret` (that bot's Keycloak client secret). Left as the placeholder, the aggregator chart omits the Secret key rather than shipping a bogus credential |
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

### Granting a human cluster-admin — `<env>/grant-cluster-admin.sh`

The bastion's access entry is Terraform (`modules/bastion/main.tf`) because its principal is a role
Terraform itself creates. A **human's** principal is not: it changes with whoever runs the apply, and
encoding "the caller" in state means the next engineer's apply revokes the previous one's access. So
that half is a standalone script, run directly like `get-signalstack-org-id.sh`:

```bash
./grant-cluster-admin.sh                     # grant whoever is running it
./grant-cluster-admin.sh <principal-arn>     # grant someone else
./grant-cluster-admin.sh --list              # existing entries
./grant-cluster-admin.sh --dry-run           # preview (works before the cluster exists)
```

**The ARN conversion is the point.** `aws sts get-caller-identity` returns an STS *session* ARN
(`arn:aws:sts::<acct>:assumed-role/AWSReservedSSO_DevOpsEngineer_<suffix>/you@example.com`); EKS access
entries take an IAM *role* ARN, so the session name has to go.

**Keep the path.** `CreateAccessEntry` validates `principalArn` against IAM, so a hand-built pathless
ARN names a role that does not exist and the call fails with
`InvalidParameterException: The specified principalArn is invalid`. SSO roles really live at
`/aws-reserved/sso.amazonaws.com/<region>/<RoleName>`. Stripping the path is the rule for the
**aws-auth ConfigMap** — the opposite API — and carrying that habit over here is what breaks it.

The script does not reconstruct the path (the region segment is the Identity Center instance's, not
necessarily the cluster's); it resolves the bare role name through `aws iam get-role`, which returns
the real ARN whatever its path. If `iam:GetRole` is denied it fails with the console lookup to run
rather than guessing.

Idempotent on both halves (`ResourceInUseException` is treated as success; the policy association is
an upsert), so it is safe on a cluster where the entry was already added by hand. The association is
the half that actually grants anything — an access entry with no policy authenticates the principal
and authorises nothing, which is what a half-finished manual attempt leaves behind.

Cluster name resolves as `CLUSTER_NAME` → the kubeconfig context (an EKS cluster ARN, so it carries
name *and* region) → `<building_block>-<environment>` from `global-values.yaml`. Region reads the
**anchor** `_cloud_storage_region`, not `global.cloud_storage_region`, because the latter is a YAML
alias and sed would hand `*cloud_storage_region` straight to the AWS CLI.

## IAM permissions boundary (every role must carry it)

Every `aws_iam_role` this repo creates sets `permissions_boundary` from
**`global.permissions_boundary_policy_name`** in `<env>/global-values.yaml` — a policy **name**, not
an ARN. Each module composes the ARN from `data.aws_partition.current` +
`data.aws_caller_identity.current.account_id`, so one name works in every account and partition and
**no account id is ever hard-coded** (the same modules deploy into four).

**Empty is valid.** The module var defaults to `""`, the local resolves to `null`, and Terraform omits
the argument — so these modules work unchanged in an account with no boundary requirement.

`template/global-values.yaml` ships the deliberately-wrong placeholder **`ExampleWorkloadBoundary`**,
not a real name. A new environment has to choose: its account's real policy name, or `""`. Deploying
the placeholder unchanged fails at the first role with `NoSuchEntity`, which is loud and traceable to
that one line. **Distinguish the two failure modes** — a *wrong* name gives `NoSuchEntity`; an *empty*
value in an account that does require a boundary gives `no identity-based policy allows the
iam:CreateRole action`, which reads like a missing permission but is an unmatched condition.

> **EXISTING ENVIRONMENTS MUST ADD THE KEY.** An `<env>/global-values.yaml` written before this
> change has no boundary key, so none is attached, and the next role creation fails with the same
> `iam:CreateRole` error this was added to fix. **Per-deployment branches don't carry it** — same
> footgun as `service_account_subjects` above. Add it to every live `<env>/global-values.yaml`.
>
> `_common/*.hcl` reads it with `try(..., null)`, not `lookup(..., "")`, so the two cases are
> distinguishable: **null** = key absent (a mistake), **`""`** = an operator deliberately choosing no
> boundary (legitimate — that is what makes these modules usable in an account with no boundary
> requirement). Both attach nothing, so this cannot fail closed; instead each module carries a
> `check "permissions_boundary_configured"` block that **warns** on null and stays silent on `""`.
> A warning rather than an error is the whole point — failing would break the no-boundary account.

This is not optional hardening. The `DevOpsEngineer` Identity Center permission set grants
`iam:CreateRole`, `iam:PutRolePolicy`, `iam:AttachRolePolicy`, `iam:DeleteRole`,
`iam:UpdateAssumeRolePolicy`, `iam:PassRole` and `iam:PutRolePermissionsBoundary` **only when the
request carries that boundary**. A role without it fails with:

```
AccessDenied: ... is not authorized to perform: iam:CreateRole ...
because no identity-based policy allows the iam:CreateRole action
```

That message is misleading — it reads as a missing permission, but it is a *conditional Allow that
did not match*. Note the wording: **"no identity-based policy allows"** means an unmatched condition,
whereas **"with an explicit deny in an identity-based policy"** means a Deny statement fired. Do not
chase this as a permissions request to the account admin; the fix is here.

The boundary is **deny-only** (allows `*`, denies the privilege-escalation set: IAM user/key
creation, `organizations:*`, `sso:*`, `identitystore:*`, `account:*`, `sts:AssumeRoot`, boundary
tampering). It grants nothing, so a role needing a new AWS service never needs the boundary amended.
The policy is **never created or modified by a deploy**. `NoSuchEntity` on `CreateRole` (as opposed
to `AccessDenied`) means the account baseline was never applied.

Baselining a new account is a separate, admin-only step: **`scripts/create-permissions-boundary.sh
--name <YourWorkloadBoundary>`**, with the document in the reviewable
`scripts/permissions-boundary.json` beside it. `--name` has no default on purpose — each org owns its
own policy, so two teams sharing these modules cannot collide on one. The script is **create-only**:
against an existing policy it reports and exits rather than publishing a new default version, since
that would silently re-cap every role already attached to it. `--verify` diffs the live policy
against the committed document; `--update` publishes a new version deliberately. Treat the LIVE
policy as authoritative when they differ.

Roles created inside third-party modules take it through their own variable, not the
`permissions_boundary` argument — both `iam-role-for-service-accounts-eks` instances in the `eks`
module (`ebs_csi_driver_irsa`, `cluster_autoscaler_irsa`) use `role_permissions_boundary_arn`. When
adding any new role, set the boundary in the same commit; a missed one only surfaces at apply time.

**Backfilling existing roles** is an in-place update — `tofu plan` shows `~`, never `-/+`. If a role
plans as a *replacement*, stop: replacing a live EKS cluster role takes the cluster down.

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
