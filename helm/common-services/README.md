# platform

Shared platform stack: **ingress-nginx + cert-manager + Let's Encrypt ClusterIssuer**. Install once per cluster, before any consumer chart (aggregator-dpg, signal-stack/dpg).

## What it deploys

| Component | Purpose | Subchart version |
|-----------|---------|------------------|
| `ingress-nginx` | LoadBalancer + ingress controller (class `nginx`) | 4.15.1 |
| `cert-manager` | TLS cert issuance, with CRDs | v1.20.2 |
| `ClusterIssuer` | Let's Encrypt production ACME (HTTP-01) | template in this chart |

`ingress-nginx` watches Ingress resources cluster-wide. `cert-manager` ClusterIssuer is cluster-scoped. Both serve all consumer namespaces.

## Install

```bash
NAMESPACE=platform   # recommended; keeps CRDs + controller out of app namespaces.

helm upgrade --install platform ./helmcharts/platform \
  -n "$NAMESPACE" --create-namespace \
  -f ./helmcharts/platform/values.yaml
```

Wait for the controller pod and cert-manager pods to be Ready before installing consumer charts (otherwise their Ingress resources sit pending and ACME challenges fail to register).

```bash
kubectl -n "$NAMESPACE" rollout status deploy/platform-ingress-nginx-controller --timeout=180s
kubectl -n "$NAMESPACE" rollout status deploy/platform-cert-manager --timeout=180s
kubectl get clusterissuer letsencrypt-prod   # READY=True
```

## Consumer chart wiring

Consumer charts (aggregator-dpg, dpg) reference platform-installed resources by name:

- `ingressClassName: nginx` on Ingress objects
- `cert-manager.io/cluster-issuer: letsencrypt-prod` annotation on Ingress objects

For aggregator-dpg, disable the bundled subcharts before deploy:

```yaml
ingress-nginx:
  enabled: false
cert-manager:
  enabled: false
```

(The ClusterIssuer in aggregator's templates is gated on `cert-manager.enabled` and won't render either.)

For dpg umbrella (signal-stack), there are no bundled subcharts to disable — just point the Ingress at `letsencrypt-prod`.

## Migration from aggregator-bundled to standalone

If you currently have ingress-nginx + cert-manager installed via the aggregator-dpg release:

1. Get the existing LB hostname; you'll need DNS to keep pointing here after migration if the new install lands on the same LB.
2. **The LB gets recreated** when ingress-nginx switches releases. Plan for ~3-5 min outage on all ingress-routed traffic + DNS update.
3. Disable the subcharts in aggregator values:
   ```yaml
   ingress-nginx:
     enabled: false
   cert-manager:
     enabled: false
   ingress:
     clusterIssuer: ""   # so aggregator stops rendering its own ClusterIssuer
   ```
4. `helm upgrade aggregator ./helmcharts/aggregator-dpg ...` to remove the resources.
5. `helm upgrade --install platform ./helmcharts/platform -n platform --create-namespace`
6. Update DNS to the new LB hostname.
7. Re-enable `ingress.clusterIssuer: letsencrypt-prod` (without `cert-manager.enabled`) in aggregator values; `helm upgrade aggregator ...` so its Ingress objects pick up the platform-managed issuer.

## Configuration knobs

See `values.yaml`. The most common edits:

- `issuer.name` — default `letsencrypt-prod`. Used by consumer Ingress annotations.
- `issuer.acmeEmail` — Let's Encrypt registration email.
- `issuer.server` — switch to `https://acme-staging-v02.api.letsencrypt.org/directory` while debugging to avoid prod rate limits.
- `ingress-nginx.controller.service.annotations` — cloud-specific LB annotations (NLB, static IP, idle timeout, etc.).
