# Helm — Blue Dots Economy

Three umbrella charts that together stand up the full Blue Dots Economy
stack on a Kubernetes cluster (typically EKS, provisioned via `opentofu/`).

Install in this strict order:

| # | Chart            | Namespace    | What it deploys                                                  |
|---|------------------|--------------|------------------------------------------------------------------|
| 1 | `platform`       | `platform`   | ingress-nginx, cert-manager, `letsencrypt-prod` ClusterIssuer    |
| 2 | `dpg`            | `dpg`        | DPG monorepo: api, ui, notification-service, match-score, pg, redis |
| 3 | `aggregator-dpg` | `aggregator` | Aggregator portal: web (BFF), api, worker, keycloak, pg, redis   |

## Quick start

From the repo root:

```bash
make install            # platform → dpg → aggregator, with readiness waits
```

Per-chart targets:

```bash
make platform-install
make dpg-install
make aggregator-install
```

Static checks (no cluster needed):

```bash
make lint
make template
```

`make help` lists every target.

## Why this order

- **platform first.** `ingress-nginx` and `cert-manager` are cluster-scoped.
  Installing them once via `platform` lets every consumer chart share the
  same LoadBalancer and the same `letsencrypt-prod` `ClusterIssuer`. Without
  this, the Ingress objects from `dpg` and `aggregator-dpg` sit Pending and
  ACME HTTP-01 challenges fail.
- **dpg second.** Self-contained app stack with its own Postgres + Redis.
  Independent of aggregator; just needs platform's Ingress + issuer.
- **aggregator-dpg last.** Same dependency on platform; longer rollout
  (Keycloak init Job runs after Postgres-0 is Ready).

## Aggregator-dpg overrides applied in this repo

`helm/aggregator-dpg/values.yaml` is patched vs. upstream:

```yaml
ingress-nginx:
  enabled: false        # platform owns the controller cluster-wide
cert-manager:
  enabled: false        # platform owns cert-manager + ClusterIssuer
```

The aggregator chart still vendors both subcharts under `charts/` (so it
remains installable standalone elsewhere), but they're inert here. The
`templates/clusterissuer.yaml` in aggregator is gated on `cert-manager.enabled`
and therefore renders nothing.

If you ever want to run `aggregator-dpg` against a cluster that has *no*
`platform` chart, flip both flags back to `true` and skip `make platform-install`.

## Prerequisites

- Kubernetes 1.24+ (EKS provisioned via `opentofu/` in this repo)
- `kubectl` with current-context pointed at the target cluster
- `helm` v3.12+
- `openssl`, `sed` (used by `dpg/install.sh` for password generation)
- DNS A/CNAME records for the host names referenced in
  `helm/dpg/values.yaml` and `helm/aggregator-dpg/values.yaml` pointing at
  the LoadBalancer hostname created by `ingress-nginx`

## Cleanup

```bash
make uninstall          # reverse order: aggregator → dpg → platform
```

Individual:

```bash
make aggregator-uninstall
make dpg-cleanup        # also drops PVCs + scrubs generated passwords
make platform-uninstall
```

`dpg-cleanup` is destructive — it deletes Postgres/Redis PVCs so the next
install can regenerate credentials cleanly.

## Per-chart docs

- [`platform/README.md`](./platform/README.md) — platform tunables (LB
  annotations, ACME server, issuer name)
- `dpg/values.yaml` — DPG image tags, hosts, runtime config, resource limits
- `aggregator-dpg/values.yaml` — aggregator hosts, Keycloak realm,
  SMTP, secrets, blue/purple overlays

## Secrets

- `helm/dpg/install.sh` generates `PG_PW`, `REDIS_PW`, `AUTH_SECRET` on first
  run and writes them back into `helm/dpg/values.yaml`. **Never commit a
  populated `values.yaml`** — `make dpg-cleanup` scrubs them back to empty.
- `helm/aggregator-dpg/values.yaml` `secrets:` block contains `change-me-*`
  placeholders that must be replaced (ideally via `global.existingSecret`
  pointing at a Secret created out-of-band) before any production rollout.
