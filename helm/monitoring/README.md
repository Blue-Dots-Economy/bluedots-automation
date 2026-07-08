# Monitoring Stack

Umbrella Helm chart for Blue Dots Economy cluster observability.
Deployed to namespace: `monitoring`

## Components

| Component | Chart | Status |
|-----------|-------|--------|
| Prometheus + Alertmanager + node-exporter + kube-state-metrics | kube-prometheus-stack 65.1.1 | Enabled |
| Grafana (bundled) | inside kube-prometheus-stack | Enabled |
| Loki | grafana/loki 6.7.1 | Enabled |
| Alloy (log shipper) | grafana/alloy | Enabled |
| Jaeger | jaegertracing/jaeger 3.1.1 | Disabled |
| OpenTelemetry Collector | open-telemetry 0.108.0 | Disabled |

---

## Configured Alerts

All alerts are defined in `values.yaml` under
`prometheus.additionalPrometheusRulesMap.bluedots-cluster-alerts.groups`. The
stock kube-prometheus-stack default rules are **disabled**
(`defaultRules.create: false`) — the tables below are the complete, curated set.

Every rule carries a `group` label (`infra` / `signals` / `aggregator` /
`common-services` / `kong` / `workload` / `storage`) alongside `severity`.

### `infra.alerts` — cluster-wide

| Alert | Fires When | For | Severity |
|-------|-----------|-----|----------|
| `NodeHighCPUUsage` | Any node CPU > 90% | 5m | critical |
| `NodeHighMemoryUsage` | Any node memory > 90% | 5m | critical |
| `NodeHighDiskUsage` | Root filesystem `/` > 90% | 10m | critical |
| `NodeNotReady` | Any node leaves the Ready state | 5m | critical |
| `ClusterPodCapacityHigh` | Total cluster pod usage > 85% of capacity | 5m | warning |

### `signals.alerts` / `aggregator.alerts` / `common-services.alerts` — per namespace

The same 5 rules are applied to each of the three namespaces (`signals`,
`aggregator`, `common-services`):

| Alert | Fires When | For | Severity |
|-------|-----------|-----|----------|
| `PodHighRestartCount` | Container restarts > 3 in 15m (CrashLoopBackOff) | immediate | critical |
| `PodOOMKilled` | Container terminated `OOMKilled` (with a recent restart) | immediate | critical |
| `PodHighCPUUsage` | Container CPU > 80% of its limit* | 5m | warning |
| `PodHighMemoryUsage` | Container memory > 80% of its limit* | 5m | warning |
| `DeploymentUnavailable` | Deployment has 0 available replicas (and is not scaled to 0) | 10m | warning |

> *Requires `resources.limits` on the container. Without limits the CPU/memory alerts stay INACTIVE (no denominator).

### `kong.alerts` — ingress gateway (per Kong service)

| Alert | Fires When | For | Severity |
|-------|-----------|-----|----------|
| `KongServiceElevatedTraffic` | Service traffic in the 3,000–5,000 req/min band | 5m | warning |
| `KongServiceHighTraffic` | Service traffic > 5,000 req/min | 5m | critical |
| `KongRateLimitSustained` | Service returns > 100 HTTP 429/min (client ignoring rate limits) | 5m | warning |
| `KongConfigTranslationBroken` | KIC cannot translate ≥ 1 Ingress/plugin into Kong config | 2m | warning |
| `KongHigh5xxRate` | Service 5xx rate > 5% **and** ≥ 15 actual 5xx in 5m | 5m | critical |
| `KongCritical4xxRate` | Service 4xx rate (excl. 429) > 25% **and** ≥ 50 actual 4xx in 5m | 5m | critical |

> Kong error/traffic alerts group by `exported_service` (the collision-renamed Kong `service` label). `KongCritical4xxRate` is the sole 4xx alert — the 10–25% warning tier and the route-level per-API 4xx/429 alerts were removed as noise sources.

### `info.alerts` — low-priority signals

| Alert | Fires When | For | Severity |
|-------|-----------|-----|----------|
| `HPAAtMaxReplicas` | An HPA has been pinned at its max replica count | 15m | info |
| `PVCUsageHigh` | A PersistentVolumeClaim is > 80% full | 5m | critical |

---

## Notification

**Channel:** Email via Gmail SMTP  
**Config:** Recipient, sender, and SMTP password come from `global-values.yaml`
(SMTP/alert anchors) and the generated `global-credentials.yaml`, layered in at
deploy time. For a truly standalone install with no overlay, set them in
`values.yaml` under `prometheus.alertmanager.config.global` and `receivers`.

**Routing:**
- `InfoInhibitor` / `Watchdog` matcher → null receiver (harmless no-op now that the stock default rules, including `Watchdog`, are disabled)
- All other alerts → email-notifications receiver (Discord receivers are used instead when Discord is enabled)
- Grouped by `alertname` + `namespace`
- `group_wait: 30s` · `group_interval: 5m` · `repeat_interval: 4h`

---

## Deploy this chart only

`monitoring` has **no dependency** on the other charts — it's safe to install
first (and `deploy_all_services` does). It is deployed to the `monitoring`
namespace as release `monitoring` (chart `name: monitoring`).

**Recommended — via `install.sh`** (layers the generated secrets):

```bash
cd opentofu/aws/<env>          # e.g. opentofu/aws/dev
bash install.sh deploy_monitoring
```

That runs, from the repo root, exactly:

```bash
ENV=opentofu/aws/<env>
helm upgrade --install monitoring helm/monitoring \
  -n monitoring --create-namespace \
  -f "$ENV/global-values.yaml" \
  -f "$ENV/global-credentials.yaml" \
  --wait --timeout 10m
```

> Only two `-f` files (config + creds) — monitoring uses neither
> `global-resources.yaml`, `global-images.yaml`, nor `global-cloud-values.yaml`.
> The two listed files must exist first: `global-values.yaml` is committed;
> `global-credentials.yaml` is generated by `bash install.sh create_tf_resources`.

**Fully standalone** (placeholder values from `values.yaml`, no SMTP/Grafana
secrets — fine for a throwaway cluster):

```bash
helm upgrade --install monitoring ./helm/monitoring -n monitoring --create-namespace --wait
```

Verify:

```bash
kubectl -n monitoring get pods
kubectl get prometheusrules -n monitoring        # alert rules loaded
```

---

## Quick Reference

```bash
# Port-forwards
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 -n monitoring
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring

# Useful URLs
# http://localhost:9090/targets  — scrape targets (all should be UP)
# http://localhost:9090/alerts   — alert rules and current state
# http://localhost:9093          — Alertmanager (active alerts, silences)
# http://localhost:3000          — Grafana (admin / see overlay for password)

# Inspect custom alert rules
kubectl get prometheusrules -n monitoring
kubectl get prometheusrule prometheus-bluedots-cluster-alerts -n monitoring -o yaml

# Alloy log shipper status
kubectl logs daemonset/monitoring-alloy -n monitoring
```

---

## Storage

| Component | PVC Size | Retention |
|-----------|----------|-----------|
| Prometheus | 20Gi gp3 | 7 days |
| Alertmanager | 2Gi gp3 | 7 days |
| Loki | 10Gi gp3 | 7 days |

StorageClass `gp3` supports online volume expansion.
