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
| `match-score` | Match-scoring service (gated `match-score.enabled`) |
| `search` | Signals search service (gated `search.enabled`) |
| `search-embeddings` | Embeddings worker for search (gated `search-embeddings.enabled`) |

Postgres/Redis credentials are consumed from the generated
`global-credentials.yaml`; the Postgres/Redis **host** comes from the layered
values (the shared common-services service, or the RDS endpoint when provisioned).

## Prerequisites

- **`common-services` must already be deployed** (shared Postgres + Redis, Kong
  ingress, `letsencrypt-prod` issuer). Signals attaches to all of them.
- `kubectl` current-context on the target cluster, `helm` v3.12+.
- The generated values files exist in the env dir (`global-credentials.yaml`,
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
  -f "$ENV/global-credentials.yaml" \
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

### Adding / editing a network

Network `network.json` schemas are mounted into the `api` pod from a ConfigMap
(`api` subchart `files/networks/<name>.json`). To add one: drop the JSON file,
append the name to `api.schemas.networks`, and add its `<network>/<domain>` pairs
to `SERVED_DOMAINS` / the `NETWORK_CONFIG_*` keys. See the inline comments in
`values.yaml`. Re-run `bash install.sh deploy_signals` (use
`kubectl -n signals rollout restart deploy/signals-ui` if a changed ConfigMap
isn't picked up).

## Uninstall

```bash
cd opentofu/aws/<env>
bash install.sh destroy_signals      # helm uninstall + delete the signals namespace
```

Signals owns no PVCs (data lives in the shared common-services Postgres/Redis),
so this does not destroy application data.
