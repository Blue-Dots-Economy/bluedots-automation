# aggregator-dpg Helm chart

Umbrella chart that bundles the Blue Dots Aggregator stack into a single
Kubernetes release. Packages web BFF + Fastify API + BullMQ worker +
Keycloak + Postgres + Redis. SMTP is wired to an external relay (SES /
SendGrid / Workspace SMTP) — no in-cluster mailcatcher.

```
                       ┌─── ingress (host: PUBLIC_HOST) ───┐
                       │  /backend/  → api  (prefix stripped)
                       │  /auth/     → keycloak
                       │  /          → web
                       └────────────────────────────────────┘
                                │
            ┌──────────┬────────┼─────────┬──────────┐
          web         api    worker    keycloak
            │          │       │          │
            └──────────┴───────┴──────────┘
                                │
                       ┌────────┴─────────┐
                   postgresql           redis
                  (Bitnami subchart)  (Bitnami subchart)
```

## Prerequisites

Cluster-side:

- Kubernetes ≥ 1.24
- `helm` ≥ 3.13
- An ingress controller — chart defaults to `ingressClassName: nginx`. Install with:

  ```bash
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace
  ```

- `cert-manager` + a `ClusterIssuer` (for TLS via Let's Encrypt). Install with:

  ```bash
  helm repo add jetstack https://charts.jetstack.io
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set installCRDs=true
  ```

Build-side:

- The custom Keycloak image with the OTP SPI baked in. Build & push:

  ```bash
  make keycloak-image
  docker tag aggregator-dpg/keycloak:26.5.5-aggregator <registry>/aggregator-dpg/keycloak:26.5.5-aggregator
  docker push <registry>/aggregator-dpg/keycloak:26.5.5-aggregator
  ```

- App images (`web`, `api`, `worker`) built from the same Dockerfiles used by
  `docker-compose`, pushed under `<global.imageRegistry>/aggregator-dpg/{web,api,worker}`.

## Install (dev)

```bash
make helm-deps               # syncs files + runs helm dependency update
make helm-install-dev        # helm upgrade --install ... with values-dev.yaml
kubectl get pods -n aggregator -w
```

Dev secrets are plaintext in `values-dev.yaml` — never reuse outside a
throwaway cluster.

## Install (prod)

1. Create the `aggregator-secrets` Secret via your secret-management tool
   (SealedSecrets / ExternalSecrets / SOPS). Required keys are listed in the
   header of `values-prod.yaml`.

2. Layer values:

   ```bash
   helm upgrade --install aggregator helm/aggregator-dpg \
     --namespace aggregator --create-namespace \
     -f helm/aggregator-dpg/values-prod.yaml \
     --set global.publicHost=portal.example.com \
     --set global.imageRegistry=ghcr.io/your-org
   ```

3. Watch pod readiness order:

   ```
   postgresql-0 → keycloak-* (initContainer renders realm) →
   aggregator-keycloak-init Job Completed → api → web + worker → Ingress
   gets TLS cert from cert-manager.
   ```

## Quirks

- **Postgres init**. The chart creates the `keycloak` database via
  `postgresql.primary.initdb.scripts` in `values.yaml`. This is identical to
  `infra/postgres/init/01-create-keycloak-db.sql` — keep both in sync.

- **Keycloak SPI**. The OTP SPI jar lives in `infra/keycloak/providers/`. The
  custom Dockerfile bakes it into the image and runs `kc.sh build`. To
  rebuild after editing the SPI: `make keycloak-image` then bump
  `keycloak.image.tag`.

- **Realm rendering**. `infra/keycloak/realms/aggregator-realm.json` contains
  `__PUBLIC_BASE_URL__` and `__SMTP_*__` placeholders. A `realm-renderer`
  initContainer (alpine + sed) substitutes them at pod startup into a
  shared `emptyDir` that the main Keycloak container imports from.

- **OIDC back-channel quirk**. In `docker-compose.yml` the web + api pods use
  `extra_hosts: ${PUBLIC_HOST}:host-gateway` so server-side OIDC discovery
  reaches Keycloak via the ingress (browsers and the BFF must see the SAME
  issuer URL). In K8s, set `global.hostAliases` to map `publicHost` → ingress
  controller cluster IP:

  ```yaml
  global:
    hostAliases:
      - ip: 10.0.0.42         # ingress-nginx Service ClusterIP
        hostnames: [portal.example.com]
  ```

  Long-term fix is to teach `apps/api` + `apps/web` about a separate
  `KEYCLOAK_INTERNAL_URL` env var for server-side calls.

- **External SMTP only**. The chart does not ship Mailpit. Wire
  `mail.provider=smtp` with a real relay (`mail.smtp.host/port/...`) or
  switch to `mail.provider=ses` with IRSA-granted SES permissions on the
  api / worker ServiceAccount.

- **Bitnami postgresql secret key**. When wiring `secrets.existingSecret`,
  the Secret MUST include a key named exactly `postgres-password` — Bitnami's
  postgresql subchart looks it up by that literal name.

## Files

| Path                                          | Role                                                            |
| --------------------------------------------- | --------------------------------------------------------------- |
| `Chart.yaml`                                  | Umbrella metadata + dependencies                                |
| `values.yaml`                                 | Defaults (dev-safe)                                             |
| `values-dev.yaml`                             | Plaintext secrets overlay, single replicas                      |
| `values-prod.yaml`                            | existingSecret + HA + IRSA overlay                              |
| `templates/_helpers.tpl`                      | Umbrella name / label / ref helpers                             |
| `templates/secrets.yaml`                      | Aggregator Secret (skipped when `global.existingSecret` set)    |
| `templates/configmap-global.yaml`             | Shared env vars (PUBLIC_HOST, S3_*, MAIL_*, OIDC URLs)          |
| `templates/configmap-keycloak-init.yaml`      | Hosts `apply-user-profile.sh` for the init Job                  |
| `templates/job-keycloak-init.yaml`            | post-install / post-upgrade hook Job (idempotent admin REST)    |
| `templates/ingress.yaml`                      | Two Ingress objects (api strip-prefix + main catch-all)         |
| `charts/{web,api,worker,keycloak}/`           | First-party subcharts                                           |
| `charts/keycloak/files/aggregator-realm.json` | Realm JSON with `__PLACEHOLDER__` markers (renderer substitutes) |
| `charts/keycloak/files/render-realm.sh`       | Synced copy of the docker-compose render script (reference)     |
| `templates/files/apply-user-profile.sh`       | Synced copy of the docker-compose init script (run by Job)      |

## Make targets

```
make helm-sync-files     # copy infra/ → chart files/
make helm-deps           # sync files + helm dependency update
make helm-lint           # helm lint with values-dev.yaml
make helm-template       # render chart to stdout
make helm-package        # build the chart tgz
make helm-install-dev    # helm upgrade --install + values-dev.yaml
make helm-uninstall      # remove release (keeps PVCs)
make keycloak-image      # build custom Keycloak image
```
