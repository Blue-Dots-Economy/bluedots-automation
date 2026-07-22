# New-Instance Deploy Runbook

A single, repeatable checklist for standing up a **fresh Blue Dots instance**
(a new environment and/or a new network/brand). It layers the *per-instance*
decisions on top of the generic mechanics already documented in
[DEPLOYMENT.md](../DEPLOYMENT.md) — this file tells you **what to change per
instance**; DEPLOYMENT.md tells you **how to run each step**. Read
[CLAUDE.md](../CLAUDE.md) once for the architecture (charts, deploy order,
values-file model, Kong ingress) before starting.

> **Two axes of "new".** A launch is usually both at once, but they are separate:
> - **New environment** — its own AWS infra + `opentofu/aws/<env>/` overlay +
>   per-deployment git branch (§A, §D–§F).
> - **New network / brand** — signals config: `network.json`, consent, brand
>   skin (§B–§C). A network can be reused across environments.

---

## Prerequisites

Same as [DEPLOYMENT.md §1](../DEPLOYMENT.md): `aws` v2, `tofu` ≥1.6, `terragrunt`
≥0.90, `kubectl` ≥1.24, `helm` ≥3.12, `bash` 4+. Plus:

- AWS creds able to create VPC/EKS/IAM/S3.
- A GHCR `read:packages` token exported as `GHCR_PAT` (image pulls).
- DNS control for the instance's public hostnames.
- The **canonical config source** in `signals-dpg` for the network you're
  deploying: `examples/schemas/<network>/{network,brand,consent}.json`.

> The knowledge in this runbook used to be scattered across `install.sh`
> comments, `CLAUDE.md`, `README.md`, and chart `values.yaml` comments — this is
> the consolidated version. When in doubt, the code + DEPLOYMENT.md win.

---

## §A — Name the instance and cut its branch

1. **Cut a per-deployment branch from `main`** (never deploy a customer env from
   a trunk branch): `git switch main && git pull && git switch -c <deployment>`
   (e.g. `purple-dots-prod`). The branch carries only that deployment's config:
   its `opentofu/aws/<env>/` dir, network JSON, image tags, and hosts.
2. **Create the environment overlay**: `cp -R opentofu/aws/template opentofu/aws/<env>`.
   The env name is the directory basename, read by `install.sh`.
3. **Set the identity anchors** in `opentofu/aws/<env>/global-values.yaml`
   (edit the **anchor block at the top only** — everything under `global:`
   references it):

   | Anchor | Meaning | Constraint |
   |--------|---------|------------|
   | `_building_block` | AWS resource-name prefix (e.g. `purple-dots`) | — |
   | `_environment` | env id (e.g. `dev`, `prod`) | ≤9 lowercase alphanumerics |
   | `_cloud_storage_region` | AWS region | e.g. `ap-south-1` |

   `_building_block` + `_environment` + `_cloud_storage_region` name the tofu
   remote-state bucket (`${building_block}-${environment}-${ACCOUNT_ID}-tfstate`).

---

## §B — Network definition (`network.json`)

The API image is **network-agnostic**; the network is supplied at runtime via a
ConfigMap. To serve network `<net>`:

1. **Place the network file** at
   `helm/signals/charts/api/files/networks/<net>.json`. Copy it from canonical
   `signals-dpg/examples/schemas/<net>/network.json` — do **not** hand-edit
   (parity between the two is being enforced; see the #181 roadmap item). It
   defines `domains[]`, each domain's `item_schemas.*.required[]`, `instances[]`,
   `actions{}`, and `dashboard_buckets{}`.
   > `consent_text` is intentionally **not** in the deployed `network.json` —
   > consent is served separately (§C).
2. **Register it** in `helm/signals/values.yaml` under `api.schemas.networks:`
   (list every network that must be mounted, including the served one and any
   cross-network peers).
3. **Select the served network** in `global-values.yaml` (via the chart's
   `api.config`):
   - `SERVED_DOMAINS: "<net>/seeker,<net>/provider"`
   - `NETWORK_CONFIG_SOURCE: local`
   - `NETWORK_CONFIG_LOCAL_FILE: "/app/schemas/<net>.json"`
   - `NETWORK_CONFIG_URLS: ""` (local mode skips cross-network fetches)
   - Anchor `_network` = `<net>`, `_signals_served_domains` = the same
     `<net>/provider,<net>/seeker`.

The `schemas-configmap.yaml` mounts these under `/app/schemas`; the deployment
carries a `checksum/schemas` annotation so pods roll when the files change.

---

## §C — Brand assets + Terms & policies

**Brand** is a UI/config *skin* over the network (`_brand` over `_network`, e.g.
`upsdm` over `blue_dot`, `onetac` over `orange_dot`). It does **not** change the
network identity.

1. **UI skin** — `global-values.yaml` anchor `_brand`; the signals UI reads
   `ui.VITE_NETWORK_NAME` (= `<net>`) and `ui.VITE_BRAND_NAME` (= `<brand>`,
   empty for the standard skin).
2. **Aggregator portal theme** — set the **keycloak theme tag** in
   `opentofu/aws/<env>/global-images.yaml` (e.g. `<net>-<brand>-develop`). This
   is the one clearly brand-specific image knob (blue→`blue_dot-upsdm-*`,
   orange→`orange_dot-onetac-*`).
3. **Brand assets** — logos/colours/typography come from canonical
   `signals-dpg/examples/schemas/<net>/brand.json` and are shipped with the UI
   image's brand assets; confirm the UI build carries `<net>`/`<brand>` assets.

**Terms & policies (consent)** are ConfigMap-delivered, not baked into the
image, so they change with a file edit + rollout:

4. **Signals consent** — source file
   `helm/signals/charts/api/files/consent/<net>.json` (terms / privacy /
   profile_creation + per-action consent text, versioned). Select it with
   `api.schemas.consentNetwork: <net>` and `CONSENT_CONFIG_SOURCE: local`
   (both in values). For a brand whose consent differs, add the **partial**
   override `helm/signals/charts/api/files/consent/<net>.<brand>.json` and set
   `api.schemas.consentBrand: <brand>` (must match `VITE_BRAND_NAME`) — the api
   deep-merges the brand partial over the network default, so **both files must
   exist**. A missing consent file fails the template render.
5. **Aggregator consent** — `helm/aggregator/files/consent/consent.json` (a
   FULL document; one network+brand per deploy).
6. After any consent change: `kubectl -n signals rollout restart deploy/signals-api`
   (consent is cached in-process; aggregator web+api need a restart too — subPath
   mounts don't hot-update).

---

## §D — Domains, TLS, auth channels, limits

Set in `opentofu/aws/<env>/global-values.yaml` (anchors) unless noted.

- **Public hosts** — `_signals_public_hosts` (seeker / provider / UI hostnames),
  `_aggregator_host`, `_grafana_host`. After the cluster is up, point DNS
  (A/CNAME) at the **Kong proxy** LoadBalancer:
  `kubectl -n common-services get svc common-services-kong-proxy`.
- **TLS** — cert-manager issues per-ingress certs via the `letsencrypt-prod`
  ClusterIssuer; `deploy_all_services` ends with `fix_acme_issuer_uri` (works
  around a cert-manager v1.20.2 bug — see CLAUDE.md).
- **Ingress** — Kong is the committed default (`kong.enabled: true`,
  `ingress-nginx.enabled: false`); rate limiting via `KongClusterPlugin` tiers
  (`rl-auth`/`rl-api`/`rl-public`). Toggle with `_api_rate_limit_enabled` /
  `_api_rate_limit_per_minute`.
- **Auth channels:**
  - **SMS OTP (MSG91)** — the auth key and each service's own template id
    (`notification-service.secrets.data.MSG91_AUTH_KEY`/`MSG91_TEMPLATE_ID`,
    aggregator `secrets.msg91AuthKey`/`keycloak.msg91TemplateId`) are
    `UPDATE_THIS_VALUE` placeholders in the **generated** `global-secrets.yaml`
    — edit them there directly (post-generation, no `global-values.yaml` edit
    or re-apply).
  - **Email (SMTP)** — anchors `_smtp_host/_port/_user/_from_display` in
    `global-values.yaml`; the notification-service and aggregator app
    passwords (`GMAIL_PASS`, `secrets.smtpPassword`) are `UPDATE_THIS_VALUE`
    placeholders in the generated `global-secrets.yaml` (Gmail App
    Password if using `smtp.gmail.com`). The `_smtp_password` anchor still
    lives in `global-values.yaml` — it only feeds monitoring's alertmanager
    (`alerting.email.smtpAuthPassword`), a separate copy.
  - `AUTH_SECRET` is generated into `global-secrets.yaml` (do not hand-set).
- **Fetch / data limits (signals api config):** `ALLOW_EXTRA_SCHEMA_DATA`
  (`"false"` = reject unknown fields) is set in the chart values. `BULK_MAX_ITEMS`
  (bulk-upload cap) is a supported api env var but not surfaced in the chart
  today — add it under `api.config` only if you need to override the app default.
- **Geocoding / maps** — both the frontend Maps JS key
  (`ui.runtimeConfig.VITE_GOOGLE_MAPS_API_KEY`) and the backend geocoding key
  (`api.secrets.data.GOOGLE_GEOCODING_API_KEY`, may be the same key with
  Geocoding API also enabled) are `UPDATE_THIS_VALUE` placeholders in the
  generated `global-secrets.yaml` — edit them there directly (no
  `global-values.yaml` edit or re-apply needed). `PHOTON_URL` defaults to the
  public Photon.
- **Other** — `_alert_email`, `_aggregator_admin_emails`,
  `global.orgHierarchyEnabled` (default `true`).

---

## §E — Image tags

Pin per-service images in `opentofu/aws/<env>/global-images.yaml` (plaintext,
per-env): `api`, `ui`, `notification-service`, `match-score`, `search`,
`search-embeddings`; aggregator `web`/`api`/`worker`; `keycloak` (brand theme
tag, §C). Prefer immutable SHAs for prod; dev may track a branch tag.

---

## §F — Provision infra, deploy, wire up

All commands run from `opentofu/aws/<env>/`.

1. **Infra** (creates the S3 backend, provisions VPC→EKS→IAM→storage→
   random_passwords→rds→output-file, writes kubeconfig, and **generates**
   `global-secrets.yaml` + `global-cloud-values.yaml`):
   ```bash
   bash install.sh                 # no-arg: create_tf_backend → create_tf_resources → apply_gp3_default_sc
   ```
   RDS is opt-in via `rds_*` anchors; when present its endpoint auto-overrides
   the in-cluster Postgres host (see CLAUDE.md → OpenTofu structure).
2. **Static checks (optional, no install):** `bash install.sh lint dry_run`.
3. **Deploy the stack** (strict order monitoring → common-services → signals →
   aggregator, then the ACME fix):
   ```bash
   export GHCR_PAT=ghp_xxx          # read:packages
   bash install.sh deploy_all_services
   ```
   or step by step: `create_namespaces_and_secrets` → `deploy_monitoring` →
   `deploy_common_services` → `deploy_signals` → `deploy_aggregator` →
   `fix_acme_issuer_uri` (see [DEPLOYMENT.md §5](../DEPLOYMENT.md)). Confirm
   common-services Postgres/Redis are Ready before signals/aggregator.
4. **Post-deploy wiring — `actingOrgId`** (required, or aggregator login fails
   with `SIGNALSTACK_ORG_NOT_REGISTERED`): after signals is up, the migrate-job
   has seeded the `network_service` org. Run:
   ```bash
   ./get-signalstack-org-id.sh
   ```
   set the returned id at `global.signalstack.actingOrgId` in `global-values.yaml`,
   then re-run `bash install.sh deploy_aggregator`.

---

## §G — Validate

1. **Platform health:**
   ```bash
   helm list -A                                   # monitoring, common-services, signals, aggregator
   kubectl -n common-services get pods,svc,pvc
   kubectl -n signals get pods,svc,ingress
   kubectl -n aggregator get pods,svc,ingress
   kubectl get certificate -A                     # READY=True once ACME completes
   ```
2. **Hostnames** resolve and serve over TLS: seeker + provider + UI +
   aggregator + grafana hosts match `global-values.yaml`.
3. **Functional end-to-end:** run the signals functional QA runbook
   (`signals-dpg/docs/operations/e2e-purple-dot-runbook.md`) — register two
   aggregators → seeker QR link → provider bulk upload → connect actions →
   verify dashboards. (That runbook is the *functional* check; this file is the
   *provisioning* runbook.)

**Acceptance:** a deployer following §A–§G stands up a fresh instance
end-to-end, with the network, brand, terms/policies, domains, and per-instance
config all set.

---

## Per-instance config surface — quick reference

| Concern | Where | Key(s) |
|--------|-------|--------|
| Identity | `global-values.yaml` | `_building_block`, `_environment`, `_cloud_storage_region` |
| Network file | `helm/signals/charts/api/files/networks/<net>.json` | + `api.schemas.networks` |
| Served network | `global-values.yaml` / `api.config` | `_network`, `SERVED_DOMAINS`, `NETWORK_CONFIG_LOCAL_FILE` |
| Brand skin | `global-values.yaml`, UI | `_brand`, `VITE_NETWORK_NAME`, `VITE_BRAND_NAME` |
| Brand theme | `global-images.yaml` | keycloak theme tag |
| Consent (signals) | `helm/signals/charts/api/files/consent/<net>[.<brand>].json` | `api.schemas.consentNetwork` / `consentBrand` |
| Consent (aggregator) | `helm/aggregator/files/consent/consent.json` | — |
| Domains / TLS | `global-values.yaml` | `_signals_public_hosts`, `_aggregator_host`, `_grafana_host` |
| Auth channels | `global-values.yaml` | `_msg91_*`, `_smtp_*` |
| Limits / rate | `global-values.yaml` / `api.config` | `ALLOW_EXTRA_SCHEMA_DATA`, `_api_rate_limit_*` (`BULK_MAX_ITEMS` = optional api env override) |
| Image tags | `global-images.yaml` | per-service `repository`/`tag` |
| Secrets | generated → `global-secrets.yaml` | `AUTH_SECRET`, DB/Redis passwords |
| actingOrgId | `global-values.yaml` (post-deploy) | `global.signalstack.actingOrgId` |

See [DEPLOYMENT.md](../DEPLOYMENT.md) for the full `install.sh` function
reference and the symptom→fix troubleshooting table.
