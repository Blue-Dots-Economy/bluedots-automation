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

### infra.alerts — cluster-wide

| Alert | Fires When | Duration | Severity |
|-------|-----------|----------|----------|
| `NodeHighCPUUsage` | Any node CPU > 80% | 5m | warning |
| `NodeHighMemoryUsage` | Any node memory > 80% | 5m | warning |
| `NodeHighDiskUsage` | Root filesystem `/` > 80% | 10m | warning |
| `NodeNotReady` | Any node leaves Ready state | 5m | critical |
| `ClusterPodCapacityHigh` | Total cluster pod usage > 85% | 5m | warning |

### signals / aggregator / common-services namespaces

Same 5 rules applied to each namespace:

| Alert | Fires When | Duration | Severity |
|-------|-----------|----------|----------|
| `PodHighRestartCount` | Container restarts > 5 in 1h | immediate | warning |
| `PodOOMKilled` | Container terminated with OOMKilled | immediate | warning |
| `PodHighCPUUsage` | Container CPU > 80% of limit* | 5m | warning |
| `PodHighMemoryUsage` | Container memory > 80% of limit* | 5m | warning |
| `DeploymentUnavailable` | Deployment drops to 0 replicas | 5m | critical |

> *Requires `resources.limits` to be set on the container. Without limits the alert stays INACTIVE.

---

## Notification

**Channel:** Email via Gmail SMTP  
**Config:** Recipient, sender, and SMTP password are set in the OpenTofu-generated `monitoring-values.yaml` overlay. For standalone use, set them in `values.yaml` under `prometheus.alertmanager.config.global` and `receivers`.

**Routing:**
- `Watchdog` and `InfoInhibitor` → suppressed (null receiver)
- All other alerts → email-notifications receiver
- Grouped by `alertname` + `namespace`
- `group_wait: 30s` · `group_interval: 5m` · `repeat_interval: 4h`

---

## Deploy

```bash
# Via install.sh (recommended — injects secrets from OpenTofu overlay)
bash opentofu/aws/<env>/install.sh deploy_monitoring

# Standalone (uses placeholder values from values.yaml)
helm upgrade --install monitoring ./helm/monitoring -n monitoring --create-namespace
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
