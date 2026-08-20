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

### `helm/monitoring/values.yaml`
| Component | Was | Now | Jump |
|---|---|---|---|
| **Prometheus** | v2.54.1 | `ghcr.io/blue-dots-economy/dhi/prometheus:3.5.5` | **MAJOR 2→3** |
| **Grafana** | 11.2.1 | `ghcr.io/blue-dots-economy/dhi/grafana:13.2.0` | **TWO MAJORS 11→13** |
| prometheus-operator | v0.77.1 | `ghcr.io/blue-dots-economy/dhi/prometheus-operator:0.93.1` | 16 minors |
| prometheus-config-reloader | v0.77.1 | `ghcr.io/blue-dots-economy/dhi/prometheus-config-reloader:0.93.1-alpine3.23` | 16 minors |
| alertmanager | v0.27.0 | `ghcr.io/blue-dots-economy/dhi/alertmanager:0.34.0-alpine3.23` | 7 minors |
| node-exporter | v1.8.2 | `ghcr.io/blue-dots-economy/dhi/node-exporter:1.12.1-alpine3.23` | 4 minors |
| kube-state-metrics | v2.13.0 | `ghcr.io/blue-dots-economy/dhi/kube-state-metrics:2.20.0` | 7 minors |
| loki | 3.1.0 | `ghcr.io/blue-dots-economy/dhi/loki:3.6.15` | 5 minors |
| alloy | v1.16.1 | `ghcr.io/blue-dots-economy/dhi/alloy:1.18.1` | 2 minors |
| alloy config-reloader | v0.91.0 | `ghcr.io/blue-dots-economy/dhi/prometheus-config-reloader:0.93.1-alpine3.23` | — |
| k8s-sidecar (grafana) | 1.27.4 | `ghcr.io/blue-dots-economy/dhi/k8s-sidecar:2.10.1-alpine3.22` | major |
| kube-webhook-certgen | v20221220 | `ghcr.io/blue-dots-economy/dhi/kube-webhook-certgen:1.8.5-alpine3.23` | — |

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

- [ ] **Prometheus (2→3)** — pod Ready; `kubectl -n monitoring logs sts/prometheus-mon-prometheus-prometheus -c prometheus | grep -iE "error|deprecated|unknown flag"`.
      v3 removed deprecated flags and the **operator generates the config**, so an
      operator/Prometheus mismatch shows up here first. Then check targets are UP
      via the Prometheus UI or `/api/v1/targets`.
- [ ] **Grafana (11→13)** — pod Ready; **the SQLite migration is ONE-WAY**, so if
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
