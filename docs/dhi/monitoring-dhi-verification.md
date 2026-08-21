# DHI migration — verification checklist

Scratch/working notes for verifying the Docker Hardened Images swap after a deploy.
Tracked in bluedots-automation#136. Delete this file before the PR merges, or move
it into `docs/` properly if it turns out to be worth keeping.

```bash
export KUBECONFIG='/home/sanketika7420/workspace/dot/blue-dots-economy/test-dev-cluster.yaml'
```

---

## What changed on this branch (`chore/dhi-hardened-images`)

### `helm/common-services/values.yaml`
| Component | Was | Now |
|---|---|---|
| cert-manager controller | quay.io/jetstack/…:v1.20.2 | `ghcr.io/blue-dots-economy/dhi/cert-manager-controller:1.20.3` |
| cert-manager webhook | v1.20.2 | `ghcr.io/blue-dots-economy/dhi/cert-manager-webhook:1.20.3` |
| cert-manager cainjector | v1.20.2 | `ghcr.io/blue-dots-economy/dhi/cert-manager-cainjector:1.20.3` |
| cert-manager acmesolver | v1.20.2 | `ghcr.io/blue-dots-economy/dhi/cert-manager-acmesolver:1.20.3` |
| cert-manager startupapicheck | v1.20.2 | `ghcr.io/blue-dots-economy/dhi/cert-manager-startupapicheck:1.20.3` |
| metrics-server | registry.k8s.io/…:0.7.1 | `ghcr.io/blue-dots-economy/dhi/metrics-server:0.9-alpine3.23` |

### `helm/monitoring/values.yaml` + chart bumps

The images could not be matched to the old charts — DHI publishes **only current
versions** (no Prometheus 2.x, no Grafana 11, no kube-state-metrics 2.13 exist in
the catalog at all), so the charts were moved forward to the images instead. The
result is that every image is now the version its chart actually expects:

| Component | Chart wants | DHI image pinned | |
|---|---|---|---|
| Prometheus | v3.14.0 | `dhi/prometheus:3.14.0` | exact |
| Alertmanager | v0.34.0 | `dhi/alertmanager:0.34.0-alpine3.23` | exact |
| prometheus-operator | v0.93.1 | `dhi/prometheus-operator:0.93.1` | exact |
| prometheus-config-reloader | v0.93.1 | `dhi/prometheus-config-reloader:0.93.1-alpine3.23` | exact |
| kube-webhook-certgen | 1.8.5 | `dhi/kube-webhook-certgen:1.8.5-alpine3.23` | exact |
| Grafana | 13.2.0 | `dhi/grafana:13.2.0` | exact |
| k8s-sidecar | 2.10.1 | `dhi/k8s-sidecar:2.10.1-alpine3.22` | exact |
| node-exporter | 1.12.1 | `dhi/node-exporter:1.12.1-alpine3.23` | exact |
| kube-state-metrics | 2.20.0 | `dhi/kube-state-metrics:2.20.0` | exact |
| Loki | 3.6.12 | `dhi/loki:3.6.15` | same minor |
| Alloy | v1.18.1 | `dhi/alloy:1.18.1` | exact |
| metrics-server | 0.9.0 | `dhi/metrics-server:0.9-alpine3.23` | exact |
| cert-manager ×5 | v1.20.2 | `dhi/cert-manager-*:1.20.3` | same minor |

Chart versions bumped to get there:

| Chart | Was | Now |
|---|---|---|
| kube-prometheus-stack | 65.1.1 (Oct 2024, operator v0.77.1) | **88.5.2** (operator v0.93.1) |
| loki | 6.7.1 (app 3.1.0) | **7.3.0** (app 3.6.12) |
| alloy | 1.8.2 (app v1.16.1) | **1.11.1** (app v1.18.1) |
| metrics-server | 3.12.1 (app 0.7.1) | **3.14.0** (app 0.9.0) |

`jaeger` and `opentelemetry-collector` are left alone — both `enabled: false`.

#### Two bugs this fixed, and one it did not

- **kube-state-metrics never went Ready.** 2.20.0 moved `/readyz` off the metrics
  port onto the telemetry port (measured: `:8080/readyz` → 404, `:8081/readyz` →
  200; on 2.13.0 both ports served it). Chart 5.25.1 hardcoded the probe path
  *and* port, so there was no values-level fix. Subchart 8.4.0 declares the
  telemetry port and probes `/readyz` there. **Fixed by the bump.**
- **node-exporter got an invalid tag.** kube-prometheus-stack 88.5.2 defaults
  `prometheus-node-exporter.image.distroless: true` (65.1.1 had no such key), and
  the subchart *appends* it to the tag — rendering
  `node-exporter:1.12.1-alpine3.23-distroless`, which DHI does not publish.
  Pinned back to `distroless: false`. **Introduced by the bump, caught by the CI
  drift check.**
- **Grafana had no datasource plugins.** Grafana 13 installs them at runtime via
  a temp file, and the DHI image's `/tmp` is not writable by uid 472, so every
  install failed and Prometheus/Loki had no plugin — pods Ready, database fine,
  dashboards blank. **NOT fixed by the bump** (no grafana subchart mounts `/tmp`);
  fixed by an `extraEmptyDirMounts` entry for `/tmp`. It is a property of the
  hardened image, not of the chart.

#### What the upgrade does NOT disturb

Verified by diffing the rendered manifests:

- `monitoring-loki` StatefulSet keeps volumeClaimTemplate `storage`; the
  `monitoring-grafana` PVC keeps its name → **no PVC is orphaned**.
- Prometheus and Alertmanager CR `storage.volumeClaimTemplate` specs are
  byte-identical → their operator-managed PVCs are untouched.
- Loki's schema is unchanged (`v13` / `tsdb` / from `2024-01-01`) → **existing
  logs stay readable**.
- Our three dashboard ConfigMaps, the `monitoring-alertmanager-config`
  configSecret, and the all-namespaces ServiceMonitor/PodMonitor/rule selectors
  all render identically.
- Resource count 84 → 81. Removals are a grafana `Role`/`RoleBinding` whose rules
  were an **empty list**, the `helm test` bats Pod (which also removes the last
  non-DHI image), and two loki objects renamed with the release prefix
  (`loki` → `monitoring-loki`). One `List` of rules became a proper
  `PrometheusRule`.

**Deliberately NOT swapped:** `bats` (runs only on `helm test`) and `busybox`
(grafana's `init-chown-data`, which the chart pins to `runAsUser: 0` — a hardened
nonroot image forced to root buys nothing and adds a failure mode).

### Images come from OUR GHCR mirror, not from dhi.io

Every ref above is `ghcr.io/blue-dots-economy/dhi/<name>` — a byte-for-byte copy
of the upstream DHI image, same digest, mirrored by
`.github/workflows/mirror-dhi-images.yml` from the list in
`.github/dhi-mirror-images.txt`.

The reason is that these are **third-party charts**: they put a registry
reference into a pod spec and the kubelet does the pull itself. Our own service
images are different — they are *built from* a DHI base in each app repo's CI
and pushed to GHCR, so the hardened layers arrive inside an image we publish and
the cluster never contacts dhi.io. Pointing the third-party charts straight at
dhi.io is what produced the `401 Unauthorized` / ImagePullBackOff on
`deploy_common_services` and `deploy_monitoring`: dhi.io refuses anonymous pulls
even for the free Apache-2.0 catalog.

A dhi.io pull Secret per namespace was the alternative and is worse: alloy,
metrics-server and kong ignore `global.imagePullSecrets`, every DHI pod runs
under its own ServiceAccount rather than `default`, the `monitoring` namespace is
not covered by the ghcr-pull rotation at all (`install.sh` passes only
common-services/signals/aggregator), and `IMAGES_PUBLIC=true` — the default —
actively clears pull secrets via `--set-json global.imagePullSecrets=[]`.

**One-time setup, and the thing most likely to bite:** a GHCR package is created
**private** on first push, and there is no REST API to change container
visibility. Each `dhi/*` package has to be flipped to public once under
<https://github.com/orgs/Blue-Dots-Economy/packages> → Package settings → Danger
Zone → Change visibility. The mirror workflow's job summary names any package
still private.

Licensing is not a blocker: the DHI catalog is Apache-2.0, which grants
redistribution outright — see the [Docker press
release](https://www.docker.com/press-release/docker-makes-hardened-images-free-open-and-transparent-for-everyone/).
The software inside each image keeps its own upstream licence, exactly as it does
for the Docker Hub bases already mirrored through GHCR today.

### `helm/aggregator/charts/worker/templates/deployment.yaml`
livenessProbe removed — it was `exec: [sh, -c, 'pgrep -f node …']` and the DHI
worker image has neither `sh` nor `pgrep`. Prerequisite for aggregator-dpg#623.

---

## Verify after `deploy_common_services`

```bash
kubectl -n common-services get pods | grep -E "cert-manager|metrics-server"
kubectl -n common-services get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.template.spec.containers[0].image}{"\n"}{end}' | grep -E "cert-manager|metrics-server"
```
- [ ] cert-manager controller / webhook / cainjector all `1/1 Running`, restarts 0
- [ ] metrics-server `1/1 Running`
- [ ] `kubectl top nodes` returns numbers (proves metrics-server is actually serving)
- [ ] `kubectl get certificate -A` — all `READY=True`
- [ ] `kubectl get challenge -A` — empty (a stuck challenge means the ACME path
      was disturbed; `bash install.sh fix_acme_issuer_uri` is the known remedy)

## Verify after `deploy_monitoring`

```bash
kubectl -n monitoring get pods
kubectl -n monitoring get pods -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[*].image}{"\n"}{end}'
```
- [ ] every pod `Running`, restarts 0
- [ ] all images show `ghcr.io/blue-dots-economy/dhi/…` except the two exceptions above

**The two risky ones, in order:**

- [ ] **Prometheus (v2.54.1 → 3.14.0, chart-matched)** — pod Ready; `kubectl -n monitoring logs sts/prometheus-mon-prometheus-prometheus -c prometheus | grep -iE "error|deprecated|unknown flag"`.
      v3 removed deprecated flags and the **operator generates the config**, so an
      operator/Prometheus mismatch shows up here first. Then check targets are UP
      via the Prometheus UI or `/api/v1/targets`.
- [ ] **Grafana (11.2.1 → 13.2.0)** — check `kubectl -n monitoring logs deploy/monitoring-grafana -c grafana | grep -i 'failed to install plugin'` is EMPTY, and that
      `/api/plugins?type=datasource` lists `prometheus` and `loki`. Blank dashboards with a healthy pod is the /tmp bug, not a Grafana fault.
      Also: pod Ready; **the SQLite migration is ONE-WAY**, so if
      this fails a tag revert alone will not fix it. Check it serves, log in, and
      confirm the ConfigMap-loaded dashboards (Kong service, Kong API, infra,
      k8s-health) still render — the `k8s-sidecar` bump (1.x→2.x) is what loads them.
- [ ] **Loki** — logs still flowing: query a recent range in Grafana Explore.
      A schema/index change across 3.1→3.6 would show as empty results despite a
      healthy pod.
- [ ] **Alloy** — DaemonSet Ready on every node; it is the log shipper feeding Loki.
- [ ] Alertmanager Ready; `kubectl -n monitoring get secret monitoring-alertmanager-config`
      still consumed (config comes from our own Secret via `configSecret`).

## Rollback

Revert the values file and redeploy — every change here is an image tag. **Except
Grafana**: its DB will already be migrated to 13, so reverting the tag leaves
Grafana 11 unable to read it. Recovery is deleting the grafana PVC (losing
dashboards/users, all of which are re-created from ConfigMaps except manual ones)
or restoring a backup.

The mirrored GHCR packages do not need to be touched on a rollback — an unused
mirror costs nothing, and re-mirroring is the slow part of rolling forward again.
