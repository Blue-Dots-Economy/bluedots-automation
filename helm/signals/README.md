# signals (chart `dpg`)

The Signals / signalstack application stack. An umbrella chart of first-party
subcharts; it connects to the **shared Postgres + Redis owned by
common-services** (it does **not** bundle its own databases).

> Directory `signals` · chart `name: dpg` · release `signals` · namespace
> `signals`. When `helm list` shows `dpg`, that's this chart.

## What it deploys

| Subchart (alias) | What it is |
|------------------|------------|
| `api` | Fastify/Node Signals API |
| `ui` | Vite/React UI behind nginx |
| `notification-service` | Email/SMS OTP + notifications (gated `notification-service.enabled`) |
| `search` | Signals search service (gated `search.enabled`) |
| `search-embeddings` | Embeddings worker for search (gated `search-embeddings.enabled`) |

Postgres/Redis credentials are consumed from the generated
`global-secrets.yaml`; the Postgres/Redis **host** comes from the layered
values (the shared common-services service, or the RDS endpoint when provisioned).

## Prerequisites

- **`common-services` must already be deployed** (shared Postgres + Redis, Kong
  ingress, `letsencrypt-prod` issuer). Signals attaches to all of them.
- `kubectl` current-context on the target cluster, `helm` v3.12+.
- The generated values files exist in the env dir (`global-secrets.yaml`,
  `global-cloud-values.yaml`) — run `bash install.sh create_tf_resources` first.
- A `ghcr-pull` image-pull secret in the `signals` namespace (private GHCR
  images) — created by `bash install.sh create_namespaces_and_secrets`.

## Deploy this chart only

**Recommended — via `install.sh`:**

```bash
cd opentofu/aws/<env>          # e.g. opentofu/aws/dev
bash install.sh deploy_signals
```

That runs, from the repo root, exactly:

```bash
ENV=opentofu/aws/<env>
helm upgrade --install signals helm/signals \
  -n signals --create-namespace \
  -f helm/global-resources.yaml \
  -f "$ENV/global-images.yaml" \
  -f "$ENV/global-values.yaml" \
  -f "$ENV/global-cloud-values.yaml" \
  -f "$ENV/global-secrets.yaml" \
  --wait --timeout 10m
```

Verify:

```bash
kubectl -n signals get pods,svc,ingress
# in-cluster smoke test (no DNS needed):
kubectl -n signals run smoke --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  -s -o /dev/null -w "signals-api %{http_code}\n" \
  http://signals-api.signals.svc.cluster.local:2742/
```

The `api` subchart runs a migrate Job (hook) against the shared `dpg` database
once Postgres is reachable — idempotent, so re-deploys are safe.

> **Aggregator depends on signals being up first:** the aggregator's
> `actingOrgId` only exists after the signals migrate Job seeds the
> `organization` table. After this deploy, run `./get-signalstack-org-id.sh`
> from the env dir and set it in the aggregator config.

## Configuration

Per-env config is layered from `opentofu/aws/<env>/global-values.yaml` (edit the
anchors at the top); chart defaults are in `helm/signals/values.yaml`. Key knobs:

| Key | Purpose |
|-----|---------|
| `global.publicHosts` | every hostname this release serves (one place to list them) — set via the `_signals_public_hosts` anchor |
| `ui.hostBindings` | multi-domain `host=network/domain` routing (single-instance multi-domain) — via `_signals_host_bindings` |
| `api.config.SERVED_DOMAINS` | which `<network>/<domain>` pairs the API serves — via `_signals_served_domains` |
| `api.config.NETWORK_CONFIG_*` | network schema source (local file mounted from a ConfigMap, or URLs) |
| `ui.runtimeConfig.*` | browser-side config rendered into `/config.js` at runtime (no rebuild) |
| `ui.runtimeConfig.VITE_COLLEGE_DATASET` | `ka` \| `up` — which state's college list the reference picker uses, **and** the one dataset the `ui` reference ConfigMap ships — via `_college_dataset` |
| `ui.reference.enabled` | deliver the college list via ConfigMap (default on). `false` → fall back to the lists baked into the UI image |
| `networkPolicy.enabled` | opt-in (**default OFF**) Ingress-only NetworkPolicy. You **must** list `aggregator` + `common-services` in `networkPolicy.allowedFromNamespaces`, or you cut the aggregator→signals path and Kong ingress |

All subcharts (including `search`) run **non-root with dropped capabilities** by
default; the `ui` nginx is the documented root exception.

### Adding / editing a network

Network `network.json` schemas are mounted into the `api` pod from a ConfigMap
(`api` subchart `files/networks/<name>.json`). To add one: drop the JSON file,
append the name to `api.schemas.networks`, and add its `<network>/<domain>` pairs
to `SERVED_DOMAINS` / the `NETWORK_CONFIG_*` keys. See the inline comments in
`values.yaml`. Re-run `bash install.sh deploy_signals` (use
`kubectl -n signals rollout restart deploy/signals-ui` if a changed ConfigMap
isn't picked up).

### Changing / adding a college reference list

The UI's college/institute autocomplete fetches `/reference/colleges-<region>.json`
from its own nginx. Those lists are ConfigMap-delivered (`signals-ui-reference`,
mounted over `/usr/share/nginx/html/reference/`), so the data changes with a
values edit + rollout — no UI image rebuild. The source JSON is **fetched fresh
from canonical signals-dpg on every deploy** by `scripts/fetch-configs.sh` (like
the network/consent config) and is not committed here.

- **Switch region:** set `_college_dataset` (`ka` | `up`) in
  `global-values.yaml`, then `bash install.sh deploy_signals`. That one value
  drives both what the browser asks for and which file is deployed, so they
  can't disagree.
- **Refresh the data:** nothing to do — the list is re-fetched from canonical
  `signals-dpg apps/ui/public/reference/` on every deploy (gitignored, never
  vendored), so it can't drift. Pin `SIGNALS_DPG_REF` to a tag/SHA for
  reproducible deploys.
- **Add a region:** add `colleges-<code>.json` to canonical
  `apps/ui/public/reference/` and set `_college_dataset` to `<code>`. A region
  missing on the fetched ref fails the deploy with the expected path, rather
  than 404ing in the browser.

**Exactly one dataset ships per release** — and that's a hard limit, not a
preference. A ConfigMap is a single etcd object capped at **1 MiB**;
`colleges-up.json` is 1.25 MB pretty-printed, so the template minifies it at
render (`fromJson | toJson`, lossless here because these files contain only
strings). Minified: `colleges-ka` ≈ 353 KB, `colleges-up` ≈ 748 KB — either fits
alone, both together (≈ 1,101 KB) do not. The ConfigMap carries a
`dpg.bluedots.io/reference-bytes` annotation so you can check headroom without
decoding it, and the render fails with a byte count if a dataset ever outgrows
`ui.reference.maxBytes`. Past that ceiling, host the lists off-cluster and point
`ui.runtimeConfig.VITE_REFERENCE_BASE_URL` at them (that host must send
permissive CORS headers — the browser fetches it directly).

Because the mount covers the whole `reference/` directory, it **shadows** the
datasets baked into the image: while `ui.reference.enabled` is true, only the
selected region is reachable. That's intended — a release serves one region.

## Uninstall

```bash
cd opentofu/aws/<env>
bash install.sh destroy_signals      # helm uninstall + delete the signals namespace
```

Signals owns no PVCs (data lives in the shared common-services Postgres/Redis),
so this does not destroy application data.
