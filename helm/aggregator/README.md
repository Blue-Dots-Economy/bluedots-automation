# aggregator (chart `aggregator-dpg`)

Umbrella chart for the Blue Dots Aggregator portal: web BFF + Fastify API +
BullMQ worker + Keycloak. It connects to the **shared Postgres + Redis owned by
common-services** and routes through the **Kong** ingress; it does not bundle its
own databases or ingress controller. SMTP is wired to an external relay.

> Directory `aggregator` · chart `name: aggregator-dpg` · release `aggregator` ·
> namespace `aggregator`.

```
                       ┌─── ingress (host: global.publicHost, class kong) ───┐
                       │  /backend/  → api  (prefix stripped)
                       │  /auth/     → keycloak
                       │  /          → web
                       └──────────────────────────────────────────────────────┘
                                │
            ┌──────────┬────────┼─────────┬──────────┐
          web         api    worker    keycloak
            └──────────┴───────┴──────────┘
                                │
              shared common-services Postgres + Redis
                    (keycloak DB lives here)
```

## What it deploys

| Subchart (alias) | What it is |
|------------------|------------|
| `web` | Next.js BFF (server-side OIDC) |
| `api` (alias `aggregator-api`) | Fastify API |
| `worker` | BullMQ background worker |
| `keycloak` | Keycloak with the OTP SPI baked in + realm renderer initContainer |

## Prerequisites

- **`common-services` deployed** (Kong ingress, `letsencrypt-prod` issuer,
  shared Postgres + Redis — the `keycloak` database lives in that Postgres).
- **`signals` deployed and migrated** — the aggregator's
  `global.signalstack.actingOrgId` is the `network_service` org id seeded by the
  signals migrate Job. **Required before login** or aggregator returns
  `SIGNALSTACK_ORG_NOT_REGISTERED`.
- The generated values files exist (`global-secrets.yaml`,
  `global-cloud-values.yaml`) — `bash install.sh create_tf_resources` first.
- A `ghcr-pull` secret in the `aggregator` namespace —
  `bash install.sh create_namespaces_and_secrets`.

## Set `actingOrgId` first

```bash
cd opentofu/aws/<env>
ORG_ID=$(./get-signalstack-org-id.sh)     # reads the shared Postgres
# set it in your env config (global.signalstack.actingOrgId):
#   global:
#     signalstack:
#       actingOrgId: "<ORG_ID>"
```

## Deploy this chart only

**Recommended — via `install.sh`:**

```bash
cd opentofu/aws/<env>          # e.g. opentofu/aws/dev
bash install.sh deploy_aggregator
```

That runs, from the repo root, exactly:

```bash
ENV=opentofu/aws/<env>
helm upgrade --install aggregator helm/aggregator \
  -n aggregator --create-namespace \
  -f helm/global-resources.yaml \
  -f "$ENV/global-images.yaml" \
  -f "$ENV/global-values.yaml" \
  -f "$ENV/global-cloud-values.yaml" \
  -f "$ENV/global-secrets.yaml" \
  --wait --timeout 10m
```

This is the **slowest** chart — pods come up in order:

```
keycloak-* (initContainer renders realm) → aggregator-keycloak-init Job Completed
  → api → web + worker → Ingress gets a TLS cert from cert-manager
```

Verify:

```bash
kubectl -n aggregator get pods,svc,ingress
kubectl get certificate -n aggregator      # READY=True once ACME completes
```

> **Brand / network.** The active network and brand skin are driven by the
> `_network` / `_brand` anchors in `opentofu/aws/<env>/global-values.yaml` (which
> also select the matching Keycloak theme image), not by per-brand overlay files.

## Quirks

- **Ingress class is `kong`** (cert-manager `letsencrypt-prod` for TLS). The
  vendored `ingress-nginx` / `cert-manager` subchart config blocks are disabled
  (`enabled: false`) — common-services owns them cluster-wide; the chart's
  `clusterissuer.yaml` is gated on `cert-manager.enabled` and renders nothing here.
- **Keycloak SPI**. The OTP SPI jar is baked into the custom Keycloak image
  (`kc.sh build`). Rebuild the image and bump `keycloak.image.tag` after editing
  the SPI.
- **Realm rendering**. `charts/keycloak/files/aggregator-realm.json` carries
  `__PUBLIC_BASE_URL__` / `__SMTP_*__` placeholders; a `realm-renderer`
  initContainer substitutes them at pod startup into a shared `emptyDir`.
- **OIDC back-channel**. Browsers and the BFF must see the **same** issuer URL.
  If server-side OIDC discovery can't reach Keycloak via the public host, set
  `global.hostAliases` to map `publicHost` → the ingress controller's cluster IP.
- **External SMTP only**. No in-cluster mail. Wire `mail.provider=smtp` with a
  real relay, or `mail.provider=ses` with IRSA-granted SES on the api/worker
  ServiceAccount.
- **Bitnami `postgres-password` key**. When wiring an existing Secret for
  Postgres, it MUST contain a key named exactly `postgres-password`.

## Key config

Per-env config layers from `opentofu/aws/<env>/global-values.yaml` (anchors at
the top); chart defaults in `values.yaml`. Notable: `global.publicHost`
(aggregator FQDN, from `_aggregator_host`), `global.signalstack.actingOrgId`,
`secrets.*` (from `global-secrets.yaml`), `mail.smtp.*` / `secrets.smtp*`.

## Uninstall

```bash
cd opentofu/aws/<env>
bash install.sh destroy_aggregator      # helm uninstall + delete the aggregator namespace
```

## Files

| Path | Role |
|------|------|
| `Chart.yaml` | Umbrella metadata + dependencies (`web`, `api`/`aggregator-api`, `worker`, `keycloak`) |
| `values.yaml` | Chart defaults |
| `templates/secrets.yaml` | Aggregator Secret (skipped when an existing Secret is wired) |
| `templates/configmap-global.yaml` | Shared env (PUBLIC_HOST, S3_*, MAIL_*, OIDC URLs) |
| `templates/job-keycloak-init.yaml` | post-install/upgrade hook Job (idempotent admin REST) |
| `templates/ingress.yaml` | Ingress objects (api strip-prefix + main catch-all), `ingressClassName: kong` |
| `charts/{web,api,worker,keycloak}/` | First-party subcharts |
| `charts/keycloak/files/aggregator-realm.json` | Realm JSON with `__PLACEHOLDER__` markers |
