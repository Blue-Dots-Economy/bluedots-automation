# campaign-manager

Umbrella Helm chart for **Campaign Manager**, the web app that lets Blue Dots operators manage voice-AI outreach campaigns. It is a standalone chart: it does not depend on the other charts and is not part of the `install.sh` flow.

Three independently deployable pieces, each its own subchart under `charts/`:

| Subchart | Purpose |
|---|---|
| `app` | The web app (Deployment, Service, Ingress), plus the database bootstrap Job and schema migrations. Always deployed. |
| `raya-sync` | CronJob loading Raya voice-bot call data into the app's database. Opt-in (`raya-sync.enabled: true`). |
| `platform-sync` | CronJob syncing Signals + Aggregator non-PII data directly into the app's database. Opt-in (`platform-sync.enabled: true`). |

`app`, `raya-sync` and `platform-sync` all connect to the **same** Postgres database with the **same** login (`global.database`) — there is one database, shared by all three. Jobs run before the release's pods start (pre-install/pre-upgrade hooks), in this order across the whole release (Helm orders hooks by weight across the umbrella *and* every subchart together): `app`'s database Job (weight 0) → `app`'s migrate Job (weight 1) → `platform-sync`'s schema Job (weight 2, creates the `platform.*` tables it writes into). `raya-sync` needs no schema Job of its own — its tables are created by `app`'s migrate Job.

The `app` and `platform-sync` Secrets are created as hooks too, so the Jobs can read them. Helm does not own hook resources: `helm uninstall` leaves them behind. Delete them by hand after an uninstall:

```bash
kubectl -n <namespace> delete secret -l app.kubernetes.io/instance=<release-name>
```

## Before you configure

- A Postgres server the cluster can reach, and its admin credentials.
- An ingress controller in the cluster, and a DNS record for your domain pointing at its load balancer (for `app`'s ingress).
- cert-manager with a ClusterIssuer, to issue the HTTPS certificate automatically.
- A namespace of your choice. Install the release into it, and create it with `--create-namespace` if it does not exist.
- The chart deploys nothing until `global.enabled: true` (`_campaign_manager_enabled` in `global-values.yaml`). It is off by default; turn it on only where Campaign Manager is needed.
- If `platform-sync` is enabled: re-run `deploy_common_services` after Signals and the aggregator are deployed, so the read-only grants land on their tables, and create the pull secret by hand first (the adhoc-scripts image is private): `GHCR_PAT=ghp_xxx bash install.sh create_campaign_manager_image_pull_secret`.
- If `raya-sync` or `platform-sync` are enabled, the images they need (`ghcr.io/blue-dots-economy/campaign-manager-pipeline`, not published yet, and `ghcr.io/blue-dots-economy/adhoc-scripts/platform-sync` respectively) and the database roles `platform-sync` reads from (`campaign_manager_signals_ro` on Signals, `aggregator_export_ro` on the aggregator database — both provisioned by `helm/common-services`' `postgresBootstrap`).

## How to configure

Defaults live in `values.yaml` (umbrella) and each subchart's own `charts/<name>/values.yaml`. Do not edit either. Copy `helm/campaign-manager.yaml.example` to `helm/campaign-manager.yaml` (git ignores it, so it is safe to put secrets in), fill in the values below, and pass it to Helm:

```bash
helm upgrade -i campaign-manager ./helm/campaign-manager -n <namespace> --create-namespace -f helm/campaign-manager.yaml
```

Use `--set key=value` instead for a one-off override. Subchart keys are set the same way Helm always addresses them from the umbrella: `--set app.image.tag=...`, `--set raya-sync.enabled=true`, `--set platform-sync.config.EXPORT_NETWORK=blue_dot`.

## Values to fill in

### Shared (`global`)

| Key | What it is | Example |
|---|---|---|
| `global.publicHost` | Public FQDN served by `app`'s ingress. | `campaign-manager.example.com` |
| `global.database.host` | Postgres host, shared by all three subcharts. | `postgres.databases.svc.cluster.local` |
| `global.database.password` | The one login's password. Set on it every time `app`'s database Job runs. | `a-strong-password` |
| `global.rayaApiKey` | Raya API key. Read by both `app` (settings UI "is it configured" check) and `raya-sync` (actually dials out) — one value, entered once. | `raya_xxx` |

### `app`

| Key | What it is | Example |
|---|---|---|
| `app.image.repository`, `app.image.tag` | Container image of the app. The tag is required. | `ghcr.io/your-org/campaign-manager`, `sha-1a2b3c4` |
| `app.imagePullSecret.private` | `true` if `app.image` is private. Pods then use the `ghcr-pull` Secret, which `install.sh create_campaign_manager_image_pull_secret` creates. Same key on raya-sync/platform-sync. | `false` |
| `app.ingress.enabled`, `.host` | Expose the app on your domain. HTTPS via the `letsencrypt-prod` ClusterIssuer is on by default. | `false`, `""` |
| `app.database.admin.user`, `.password` | Admin account, used only by the database Job to create the login and the database. | `postgres`, `postgres-admin-password` |
| `app.secrets.SESSION_SECRET` | Key that signs login sessions. Must be at least 32 characters. | generate with `openssl rand -hex 32` |
| `app.secrets.CRON_SECRET` / `.CRON_SECRET_PREVIOUS` | Secret that authenticates the sync hook called by your scheduler; previous value while rotating. | `a-long-random-string` |
| `app.secrets.GOOGLE_SERVICE_ACCOUNT_JSON` | Google service-account JSON, as one string. | `'{"type":"service_account",...}'` |
| `app.migrate.enabled` | Run the app's schema migrations before every install/upgrade. Already-applied migrations are skipped. | `true` |
| `app.secrets.KEYCLOAK_CLIENT_SECRET` | Secret of the Keycloak client the app signs people in with. Required. `install.sh` deploys fill it from the generated `campaign_manager_secret`. | `xxx` |

### `app` Keycloak login

People sign in through Keycloak with an emailed code. The app does not start without these, and the render fails if one can't be worked out. On `install.sh` deploys they are derived from the shared Keycloak globals, so only `bootstrapAdminEmail` needs setting (`_campaign_manager_admin_email` in `global-values.yaml`).

| Key | What it is | Example |
|---|---|---|
| `app.appBaseUrl` | Public address of the app. Empty = `<global.publicProtocol>://<app.ingress.host or global.publicHost>`. | `https://campaign-manager.example.com` |
| `app.keycloak.baseUrl` | Public Keycloak address, as browsers reach it. Empty = derived from `global.keycloak`. | `https://auth.example.com/auth` |
| `app.keycloak.internalBaseUrl` | Optional in-cluster Keycloak address for server-side calls. Empty = `global.keycloak.internalBaseUrl`, else the public one. | `http://keycloak-keycloak.common-services.svc.cluster.local:8080/auth` |
| `app.keycloak.realm` | Realm. Empty = `global.keycloakRealm`. | `bluedots` |
| `app.keycloak.clientId` | Client the app signs in with. Its service account looks up and creates users, so it needs realm-management `view-users`, `query-users` and `manage-users` (the shared realm grants them). | `campaign-manager` |
| `app.bootstrapAdminEmail` | First admin. The migrate Job creates it in Keycloak and the app when the app has no active admin, and fails if that Keycloak account is disabled or its email is unverified. Empty = no admin is created. | `admin@example.com` |

The client must allow `<app base URL>/auth/keycloak/callback` as a redirect URI and `<app base URL>/login` as a post-logout redirect URI. In the shared realm both come from `keycloak.campaignManagerRedirectUris` (`_campaign_manager_redirect_uris`).

To keep credentials out of Helm values, create the Secret yourself and set `app.secrets.existingSecret` to its name. It must carry: `DATABASE_URL`, `SESSION_SECRET`, `CRON_SECRET`, `CRON_SECRET_PREVIOUS` (optional), `RAYA_API_KEY`, `GOOGLE_SERVICE_ACCOUNT_JSON`, `KEYCLOAK_CLIENT_SECRET`, plus `DB_ADMIN_PASSWORD`/`DB_PASSWORD` if `app.dbInit.enabled`.

### `raya-sync`

Set `raya-sync.enabled: true` to deploy its CronJob.

| Key | What it is | Example |
|---|---|---|
| `raya-sync.image.repository`, `.tag` | Pipeline image. The tag is required. | `ghcr.io/blue-dots-economy/campaign-manager-pipeline`, no tag |
| `raya-sync.schedule` | Cron expression, in `raya-sync.timeZone` (default `Asia/Kolkata`). | `"0 2 * * *"` |
| `raya-sync.config.PD_REFRESH_DAYS`, `.PD_TEST_BATCHES` | Pipeline tuning, passed straight through. | leave empty for the image's own defaults |
| `raya-sync.args` | Extra `run_pipeline.py` arguments. Defaults to `["--skip", "platform"]` — Signals sync is `platform-sync`'s job now, not this one's. | `["--skip", "platform"]` |

To run it once without waiting for the schedule:
```bash
kubectl -n <namespace> create job --from=cronjob/<release-name>-raya-sync raya-sync-manual
```

### `platform-sync`

Set `platform-sync.enabled: true` to deploy its CronJob. Backed by `adhoc-scripts/platform-sync`.

| Key | What it is | Example |
|---|---|---|
| `platform-sync.image.repository`, `.tag` | Platform-sync image. The tag is required. | `ghcr.io/blue-dots-economy/adhoc-scripts/platform-sync`, no tag |
| `platform-sync.schedule` | Cron expression, in `platform-sync.timeZone` (default `Asia/Kolkata`). | `"0 */4 * * *"` |
| `platform-sync.config.INSTANCE_ID` | This deployment's Signals instance id. Never change it once set. | `""` |
| `platform-sync.config.EXPORT_NETWORK` | Signals network this deployment reads. | `purple_dot` or `blue_dot` |
| `platform-sync.secrets.SIGNALS_DATABASE_URL` | Read-only Postgres URL to the Signals database. | `postgresql://campaign_manager_signals_ro:xxx@host:5432/dpg` |
| `platform-sync.secrets.AGG_DATABASE_URL` | Read-only Postgres URL to the aggregator database. | `postgresql://aggregator_export_ro:xxx@host:5432/aggregator` |

To run it once without waiting for the schedule:
```bash
kubectl -n <namespace> create job --from=cronjob/<release-name>-platform-sync platform-sync-manual
```
