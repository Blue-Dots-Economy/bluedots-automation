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

`output-file` is what makes `preflight` pass: it generates the two gitignored files (`global-credentials.yaml` = all secrets; `global-cloud-values.yaml` = cloud outputs + computed hosts/origins + the RDS host above). After editing config that feeds them, regenerate just these with `bash install.sh apply_tf_output_file` rather than re-running the whole apply.

## Private-cluster access (`pritunl` + `bastion`, both `*_enabled` default `true`)

Two optional modules that make the cluster reachable without a public EKS endpoint or a public deploy box:

- **`pritunl`** — Pritunl OpenVPN server (Ubuntu 22.04 + MongoDB via cloud-init) in a **public** subnet with an Elastic IP; the single front door routing the VPC CIDR to connected laptops. Its SG opens SSH 22 / OpenVPN 1194 UDP+TCP / web-admin 443 to `pritunl_ingress_cidrs`, which **defaults to `0.0.0.0/0` — restrict it** to office/home CIDRs (this SG gates all downstream cluster access). `t3.small` minimum (MongoDB RAM). It has `lifecycle.ignore_changes` on `associate_public_ip_address` so day-2 SG edits don't recreate it (recreation would wipe the hand-configured Pritunl org/user/server — set up once by hand over SSH).
- **`bastion`** — Amazon-Linux-2023 deploy workstation in a **private** `private-eks-*` subnet, **no public IP**, SG allows SSH from the VPC CIDR only (reachable only after VPN connect). Ships kubectl/helm/aws-cli/k9s/git/yq and pre-runs `aws eks update-kubeconfig` at boot. Mapped into the cluster with `AmazonEKSClusterAdminPolicy` via an EKS access entry (`authentication_mode = API_AND_CONFIG_MAP`). No repo code baked in — `git pull` + deploy from here.

Access is **SSH public key only** (`bastion_authorized_keys`, shared by both hosts; private keys stay with devs, so nothing secret lands in tfstate). Add/remove a key or CIDR in `global-values.yaml` and re-apply `bastion`/`pritunl`. To go fully private-endpoint: set both `eks_endpoint_public_access` and `eks_endpoint_private_access` `true`, verify from the bastion, then flip public access `false`.

## Infra state & secrets

tfstate lives in an S3 bucket (encrypted, versioned, private) — never committed; `.terraform/`, `*.tfstate`, `*.tfvars`, generated `tf.sh`/`global-cloud-values.yaml`/`global-credentials.yaml` are all gitignored. App secrets are generated by `random_passwords` + `output-file` into the gitignored `global-credentials.yaml`.

**Operator-provided secrets — `global-secrets.yaml` (#1.2a).** Real **SMTP password / MSG91 auth key / Gmail pass / Google Maps API key** must NOT go in the committed `global-values.yaml` (its `_smtp_password`/`_msg91_auth_key` anchors stay as `changeme` placeholders, and only non-secret config — host/port/from/template-id — is edited there). Instead, copy `global-secrets.yaml.example` → **`global-secrets.yaml`** (gitignored) and put the real values there at their chart-keyed paths. `install.sh` layers `-f global-secrets.yaml` **LAST** in every helm deploy (and `dry_run`) via the `SECRETS_OPT` array — only when the file exists — so it overrides both the committed placeholders and the generated `global-credentials.yaml`, keeping real secrets out of every committed file. Absent file ⇒ deploys behave exactly as before.
