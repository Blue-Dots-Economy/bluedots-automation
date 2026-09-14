#!/usr/bin/env bash
# Unit-test the notification-service alerting rules with promtool.
#
# Mirrors helm/monitoring/tests/run.sh, but these rules live in a real
# PrometheusRule template rather than inside values.yaml, so the render is a
# `--show-only` on the subchart.
#
# The two findings this exists to catch are both invisible to `helm lint` and
# `helm template`, which is how they reached review:
#   * increase() on a GAUGE — counter-reset correction makes a DLQ drain read as
#     a reset and extrapolate upward, so draining the DLQ fires the DLQ alert.
#   * a failure RATIO with no volume floor — on a low-traffic path one failure
#     retried to success is already 0.5, so two blips page `critical`.
#
# promtool comes from the prometheus image so no local install is needed. The
# image runs as uid 65534, hence --user 0:0 to read the bind mount.
set -euo pipefail
cd "$(dirname "$0")"
CHART="../charts/notification-service"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

helm template ns "$CHART" --namespace signals --set config.SMTP_AWS_SES=true \
  --show-only templates/prometheusrule.yaml \
  | python3 -c "
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get('kind') == 'PrometheusRule':
        print(yaml.safe_dump({'groups': d['spec']['groups']}, sort_keys=False, allow_unicode=True))
" > "$OUT/rules-fixed.yaml"

cp notification-alerts_test.yaml "$OUT/"
chmod -R a+rX "$OUT"

docker run --rm --user 0:0 -v "$OUT:/w" -w /w \
  --entrypoint promtool prom/prometheus:v3.5.0 check rules rules-fixed.yaml
docker run --rm --user 0:0 -v "$OUT:/w" -w /w \
  --entrypoint promtool prom/prometheus:v3.5.0 test rules notification-alerts_test.yaml
