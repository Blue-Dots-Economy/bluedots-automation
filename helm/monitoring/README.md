# Monitoring Stack

Umbrella Helm chart for Blue Dots Economy cluster observability.
Deployed to namespace: `monitoring`

## Components

| Component | Chart | Status |
|-----------|-------|--------|
| Prometheus + Alertmanager + node-exporter + kube-state-metrics | kube-prometheus-stack 65.1.1 | Enabled |
| Grafana (bundled) | inside kube-prometheus-stack | Disabled (enable when ready) |
| Loki | grafana/loki 6.7.1 | Disabled |
| Promtail | grafana/promtail 6.16.6 | Disabled |
| Jaeger | jaegertracing/jaeger 3.1.1 | Disabled |
| OpenTelemetry Collector | open-telemetry 0.108.0 | Disabled |

---

## Configured Alerts

### infra.alerts — Node-level (cluster-wide)

| Alert | Fires When | Duration | Severity |
|-------|-----------|----------|----------|
| `NodeHighCPUUsage` | Any node CPU > 80% | 5 minutes continuous | warning |
| `NodeHighMemoryUsage` | Any node memory > 80% | 5 minutes continuous | warning |
| `NodeHighDiskUsage` | Root filesystem `/` > 80% | 10 minutes continuous | warning |
| `NodeNotReady` | Any node leaves Ready state | 5 minutes continuous | critical |

### signals.alerts — signals namespace

| Alert | Fires When | Duration | Severity |
|-------|-----------|----------|----------|
| `PodHighRestartCount` | Any container restarts > 5 times in 1h | immediately | warning |
| `PodOOMKilled` | Any container terminated with OOMKilled reason | immediately | warning |
| `PodHighCPUUsage` | Container CPU > 80% of its limit* | 5 minutes | warning |
| `PodHighMemoryUsage` | Container memory > 80% of its limit* | 5 minutes | warning |
| `DeploymentUnavailable` | Any deployment drops to 0 available replicas | 5 minutes | critical |

### aggregator.alerts — aggregator namespace

Same 5 rules as signals.alerts, filtered to `namespace="aggregator"`.

### common-services.alerts — common-services namespace

Same 5 rules as signals.alerts, filtered to `namespace="common-services"`.

> *Pod CPU/memory alerts require `resources.limits` to be set on the container in the deployment spec. If no limit is set, the alert stays INACTIVE (no false positives).

---

## Notification

**Channel:** Email via Gmail SMTP
**Recipient:** shashankp@sanketika.in
**Sender:** dummysender111@gmail.com

**Routing:**
- `Watchdog` and `InfoInhibitor` → null (suppressed, never emailed)
- All other alerts → email-notifications receiver
- Grouped by `alertname` + `namespace` — multiple alerts in the same group = 1 email
- `group_wait: 30s` — waits 30s to collect related alerts before sending
- `repeat_interval: 4h` — resends if still firing after 4 hours

**TODO:** Move `smtp_auth_password` out of values.yaml into a Kubernetes Secret for production.

---

## Quick Reference

```bash
# Port-forwards (run in separate terminals)
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring
kubectl port-forward svc/monitoring-kube-prometheus-alertmanager 9093:9093 -n monitoring

# Useful pages
# http://localhost:9090/targets  — all scrape targets (should all be UP)
# http://localhost:9090/alerts   — all alert rules and current state
# http://localhost:9093          — Alertmanager (active alerts, silences)

# Check what PrometheusRule CRDs exist
kubectl get prometheusrules -n monitoring

# Read our custom rules live
kubectl get prometheusrule prometheus-bluedots-cluster-alerts -n monitoring -o yaml

# Deploy / upgrade
helm upgrade --install monitoring ./helm/monitoring --namespace monitoring --create-namespace
```

---

## Storage

| Component | PVC Size | Retention |
|-----------|----------|-----------|
| Prometheus | 20Gi gp3 | 7 days |
| Alertmanager | 2Gi gp3 | 168h (7 days) |

StorageClass `gp3` supports volume expansion — resize without recreating the PVC.
