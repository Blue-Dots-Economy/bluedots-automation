# campaign-manager

Helm chart for **Campaign Manager**, the web app that lets Blue Dots operators manage voice-AI outreach campaigns. It is a standalone chart: it does not depend on the other charts and is not part of the `install.sh` flow.

## What it deploys

| Resource | Purpose |
|---|---|
| Deployment, Service | The Campaign Manager web app (listens on port 3000). |
| Ingress | Exposes the app on your domain, with an HTTPS certificate from cert-manager. |
| ConfigMap, Secret | Non-secret settings and credentials, injected into the app as environment variables. |
| CronJob | Purple Dots data pipeline. Loads Raya calls and the platform S3 dump into Postgres. |
| Job | Runs after every install and upgrade. Creates the pipeline's Postgres user, database and tables if they are missing. |

The app stores its data in Supabase, which is external to the chart. The pipeline writes to a Postgres you point it at.

## Before you configure

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

### App settings (`config`)

| Key | What it is | Example |
|---|---|---|
| `config.SUPABASE_URL` | Supabase project URL. | `https://abcd1234.supabase.co` |
| `config.PURPLE_SUPABASE_URL` | Purple Dots Supabase project URL. | `https://efgh5678.supabase.co` |
| `config.PURPLE_CUTOVER` | Purple Dots cutover flag. | `"false"` |

### App credentials (`secrets`)

| Key | What it is | Example |
|---|---|---|
| `secrets.SUPABASE_PUBLISHABLE_KEY` | Supabase publishable key. | `sb_publishable_xxx` |
| `secrets.SUPABASE_SERVICE_ROLE_KEY` | Supabase service-role key. | `sb_secret_xxx` |
| `secrets.PURPLE_SUPABASE_SERVICE_ROLE_KEY` | Service-role key of the Purple Dots project. | `sb_secret_xxx` |
| `secrets.LOVABLE_CRON_SECRET` | Secret that authenticates cron calls to the app. | `a-long-random-string` |
| `secrets.LOVABLE_CRON_SECRET_PREVIOUS` | The previous cron secret, still accepted while you rotate. | `the-old-random-string` |
| `secrets.RAYA_API_KEY` | Raya API key. | `raya_xxx` |
| `secrets.GOOGLE_SHEETS_API_KEY` | Google Sheets API key. | `AIza...` |
| `secrets.GOOGLE_SERVICE_ACCOUNT_JSON` | Google service-account JSON, as one string. | `'{"type":"service_account",...}'` |
| `secrets.LOVABLE_API_KEY` | Lovable API key. | `lov_xxx` |

To keep credentials out of Helm values, create a Secret yourself with the same keys and set `secrets.existingSecret` to its name.

### Purple Dots pipeline (`pipeline`)

Set `pipeline.enabled: true` to deploy the CronJob and the database Job.

| Key | What it is | Example |
|---|---|---|
| `pipeline.image.repository`, `pipeline.image.tag` | Pipeline image. The tag is required. | `ghcr.io/your-org/purple-dots`, `v1.0.0` |
| `pipeline.schedule` | Cron expression for the run, in `pipeline.timeZone` (default `Asia/Kolkata`). | `"0 2 * * *"` |
| `pipeline.config.BASE_URL` | Host that serves `/v1/campaign/dump`, for the S3 dump. | `https://aggregator.example.com` |
| `pipeline.config.KEYCLOAK_URL` | Keycloak base URL. | `https://auth.example.com/auth` |
| `pipeline.config.REALM`, `pipeline.config.CLIENT_ID` | Keycloak realm and the service-account client. | `bluedots`, `campaign-manager` |
| `pipeline.secrets.RAYA_API_KEY` | Raya API key. | `raya_xxx` |
| `pipeline.secrets.CLIENT_SECRET` | Secret of the Keycloak client. | `xxx` |
| `pipeline.database.host` | Postgres host. | `postgres.databases.svc.cluster.local` |
| `pipeline.database.name`, `pipeline.database.user` | Database and user the pipeline uses. Created for you if missing. Defaults to `purple`. | `purple`, `purple` |
| `pipeline.database.password` | Password for that user. | `a-strong-password` |
| `pipeline.dbInit.admin.user`, `pipeline.dbInit.admin.password` | Admin account used once to create the user and database. Only the database Job sees it. | `postgres`, `xxx` |
| `pipeline.args` | Extra arguments for the run, for example to skip a stage. | `["--skip", "inbound"]` |

To run the pipeline once without waiting for the schedule:

```bash
kubectl -n <namespace> create job --from=cronjob/<release-name>-pipeline pipeline-manual
```
