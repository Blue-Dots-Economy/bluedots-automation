# campaign-manager

Helm chart for **Campaign Manager**, the web app that lets Blue Dots operators manage voice-AI outreach campaigns. It stores its data in Postgres. It is a standalone chart: it does not depend on the other charts and is not part of the `install.sh` flow.

## What it deploys

| Resource | Purpose |
|---|---|
| Deployment, Service | The Campaign Manager web app (listens on port 3000). |
| Ingress | Exposes the app on your domain, with an HTTPS certificate from cert-manager. |
| ConfigMap, Secret | One ConfigMap for settings and one Secret for every credential in the chart. Each pod reads only the keys it needs. |
| Database Job | Runs after every install and upgrade. Creates the Postgres login, the database and its schemas if they are missing. |
| Migrate Job | Runs after the database Job. Applies the app's schema migrations. |
| Pipeline schema Job | Runs after the Migrate Job. Creates the pipeline's own tables (`purple_users`, `purple_items`, `purple_actions`) in the `platform` schema. Only deployed with the pipeline. |
| CronJob | Purple Dots data pipeline. Loads Raya calls and the platform S3 dump into the same database, which is where the app reads them. |

The app, the migrations and the pipeline all connect with one Postgres login. The jobs run in this order: Database Job, Migrate Job, Pipeline schema Job.

## Before you configure

- A Postgres server the cluster can reach, and its admin credentials.
- An ingress controller in the cluster, and a DNS record for your domain pointing at its load balancer.
- cert-manager with a ClusterIssuer, to issue the HTTPS certificate automatically.
- A namespace of your choice. Install the release into it, and create it with `--create-namespace` if it does not exist.

## How to configure

Defaults live in `values.yaml`. Do not edit it. Copy `helm/campaign-manager.yaml.example` to `helm/campaign-manager.yaml` (git ignores it, so it is safe to put secrets in), fill in the values below, and pass it to Helm:

```bash
helm upgrade -i campaign-manager ./helm/campaign-manager -n <namespace> --create-namespace -f helm/campaign-manager.yaml
```

Use `--set key=value` instead for a one-off override.

## Values to fill in

### Image

| Key | What it is | Example |
|---|---|---|
| `image.repository` | Container image of the app. | `ghcr.io/your-org/campaign-manager` |
| `image.tag` | Image tag to deploy. There is no usable default, so always set it. | `sha-1a2b3c4` |

If the registry is private, create an image pull secret named `ghcr-pull` in the namespace, or list your own names under `global.imagePullSecrets`.

### Ingress

| Key | What it is | Example |
|---|---|---|
| `ingress.enabled` | Set to `true` to create the Ingress. | `true` |
| `ingress.className` | Ingress class in your cluster (`kubectl get ingressclass`). | `kong` |
| `ingress.host` | Your domain. | `campaign-manager.example.com` |
| `ingress.annotations` | Annotations for your controller. For automatic HTTPS, name your ClusterIssuer (`kubectl get clusterissuer`). | `cert-manager.io/cluster-issuer: letsencrypt-prod` |
| `ingress.tls.enabled`, `ingress.tls.secretName` | Serve HTTPS from this certificate Secret. | `true`, `campaign-manager-tls` |

### Database

| Key | What it is | Example |
|---|---|---|
| `database.host` | Postgres host. | `postgres.databases.svc.cluster.local` |
| `database.name` | Database to create and use. Defaults to `campaign_manager`. | `campaign_manager` |
| `database.admin.user`, `database.admin.password` | Admin account, used only by the database Job to create the login and the database. | `postgres`, `postgres-admin-password` |
| `database.user`, `database.password` | The one login used by the app, the migrations and the pipeline. The user defaults to `campaign_manager`. The password is set on it every time the database Job runs. | `campaign_manager`, `a-strong-password` |

### Migrations

| Key | What it is | Example |
|---|---|---|
| `migrate.enabled` | Run the migrations after every install and upgrade. Already applied migrations are skipped. | `true` |
| `migrate.image.repository`, `migrate.image.tag` | Only to run the migrations from a different image. Empty means the app image, which contains them. | leave empty |
| `migrate.command` | Command that applies the migrations. | `["node", "migrate/migrate.mjs"]` |

### App credentials (`secrets`)

| Key | What it is | Example |
|---|---|---|
| `secrets.SESSION_SECRET` | Key that signs login sessions. | `a-long-random-string` |
| `secrets.CRON_SECRET` | Secret that authenticates the sync hook called by your scheduler. | `a-long-random-string` |
| `secrets.CRON_SECRET_PREVIOUS` | The previous cron secret, still accepted while you rotate. Leave empty otherwise. | `the-old-random-string` |
| `secrets.RAYA_API_KEY` | Raya API key. | `raya_xxx` |
| `secrets.GOOGLE_SERVICE_ACCOUNT_JSON` | Google service-account JSON, as one string. | `'{"type":"service_account",...}'` |

To keep credentials out of Helm values, create the Secret yourself and set `secrets.existingSecret` to its name. It must carry these keys: `DATABASE_URL`, `SESSION_SECRET`, `CRON_SECRET`, `CRON_SECRET_PREVIOUS` (optional), `RAYA_API_KEY`, `GOOGLE_SERVICE_ACCOUNT_JSON`, plus `CLIENT_SECRET` for the pipeline and `DB_ADMIN_PASSWORD` and `DB_PASSWORD` for the database Job. The pipeline uses the same `RAYA_API_KEY` as the app.

### Purple Dots pipeline (`pipeline`)

Set `pipeline.enabled: true` to deploy the CronJob. It uses the database above.

| Key | What it is | Example |
|---|---|---|
| `pipeline.image.repository`, `pipeline.image.tag` | Pipeline image. The tag is required. | `ghcr.io/your-org/purple-dots`, `v1.0.0` |
| `pipeline.schedule` | Cron expression for the run, in `pipeline.timeZone` (default `Asia/Kolkata`). | `"0 2 * * *"` |
| `pipeline.config.BASE_URL` | Host that serves `/v1/campaign/dump`, for the S3 dump. | `https://aggregator.example.com` |
| `pipeline.config.KEYCLOAK_URL` | Keycloak base URL. | `https://auth.example.com/auth` |
| `pipeline.config.REALM`, `pipeline.config.CLIENT_ID` | Keycloak realm and the service-account client. | `bluedots`, `campaign-manager` |
| `pipeline.secrets.CLIENT_SECRET` | Secret of the Keycloak client. | `xxx` |
| `pipeline.args` | Extra arguments for the run, for example to skip a stage. | `["--skip", "platform"]` |

To run the pipeline once without waiting for the schedule:

```bash
kubectl -n <namespace> create job --from=cronjob/<release-name>-pipeline pipeline-manual
```
