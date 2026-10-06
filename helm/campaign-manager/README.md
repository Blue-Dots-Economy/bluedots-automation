# Deploying Campaign Manager on Kubernetes

This guide deploys Campaign Manager on your cluster using the Helm chart in the `bluedots-automation` repository (`helm/campaign-manager`, branch `alimco-tcs`).

## What you need

- A Kubernetes cluster and `kubectl` access to it
- Helm 3
- An ingress controller in the cluster
- A domain name, with a DNS record pointing to the ingress controller's load balancer
- cert-manager with a ClusterIssuer, for HTTPS
- The container image details, Supabase URLs and keys

Make sure you are connected to the right cluster before you start:

```bash
kubectl config current-context
```

## Step 1. Get the chart

```bash
git clone -b alimco-tcs https://github.com/Blue-Dots-Economy/bluedots-automation.git
cd bluedots-automation
```

## Step 2. Create the namespace

```bash
kubectl create namespace campaign-manager
```

## Step 3. Create the overrides file

Create a file named `global-overrides.yaml`. It contains secrets, so do not commit it to git.

```yaml
image:
  repository: <image-repository>
  tag: <image-tag>

ingress:
  enabled: true
  className: kong                   # your ingress class: kubectl get ingressclass
  host: campaign-manager.example.com   # your domain
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # your ClusterIssuer: kubectl get clusterissuer
  tls:
    enabled: true
    secretName: campaign-manager-tls

config:
  SUPABASE_URL: ""
  PURPLE_SUPABASE_URL: ""
  PURPLE_CUTOVER: ""

secrets:
  SUPABASE_PUBLISHABLE_KEY: ""
  SUPABASE_SERVICE_ROLE_KEY: ""
  PURPLE_SUPABASE_SERVICE_ROLE_KEY: ""
  LOVABLE_CRON_SECRET: ""
  LOVABLE_CRON_SECRET_PREVIOUS: ""
  RAYA_API_KEY: ""
  GOOGLE_SHEETS_API_KEY: ""
  LOVABLE_API_KEY: ""
  GOOGLE_SERVICE_ACCOUNT_JSON: ""   # service-account JSON as one string
```

Fill in every value. All available settings are listed in `helm/campaign-manager/values.yaml`.

If the image is private, also create the pull secret the chart expects:

```bash
kubectl -n campaign-manager create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<github-token-with-read:packages>
```

## Step 4. Install

```bash
helm upgrade -i campaign-manager ./helm/campaign-manager \
  -n campaign-manager \
  -f global-overrides.yaml
```

## Step 5. Check it works

```bash
kubectl -n campaign-manager get pods,ingress,certificate
```

The pod should be `Running` and ready, and the certificate `READY: True` (this can take a couple of minutes). Then open `https://<your-domain>`.

If you are not mapping the app to a domain, you can use `kubectl port-forward` on the `campaign-manager` service to access it instead.

## Update or remove

To update, change `global-overrides.yaml` and run the Step 4 command again.

To remove:

```bash
helm -n campaign-manager uninstall campaign-manager
kubectl delete namespace campaign-manager
```

## If something goes wrong

| Problem | What to check |
|---|---|
| Pod in `ImagePullBackOff` | The image details are wrong, or the image is private and the `ghcr-pull` secret is missing |
| Pod running but not ready | `kubectl -n campaign-manager logs deploy/campaign-manager` — usually a wrong Supabase value |
| Ingress returns 404 | `className` or `host` in the overrides file is wrong |
| Certificate not ready | The domain does not resolve to the load balancer yet, or the ClusterIssuer name is wrong |
