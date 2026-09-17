#!/usr/bin/env bash
# Unit-test the Kong alerting rules with promtool.
#
# The rules live inside values.yaml (additionalPrometheusRulesMap), so they must
# be rendered before promtool can see them: render the chart, pull the single
# PrometheusRule out, then run the test file against it.
#
# promtool comes from the prometheus image so no local install is needed. The
# image runs as uid 65534, hence --user 0:0 to read the bind mount.
set -euo pipefail
cd "$(dirname "$0")"
CHART=".."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

helm template mon "$CHART" --namespace monitoring \
  | python3 -c "
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get('kind') == 'PrometheusRule':
        print(yaml.safe_dump({'groups': d['spec']['groups']}, sort_keys=False, allow_unicode=True))
" > "$OUT/rules-fixed.yaml"

cp kong-alerts_test.yaml "$OUT/"
chmod -R a+rX "$OUT"

docker run --rm --user 0:0 -v "$OUT:/w" -w /w \
  --entrypoint promtool prom/prometheus:v3.5.0 check rules rules-fixed.yaml
docker run --rm --user 0:0 -v "$OUT:/w" -w /w \
  --entrypoint promtool prom/prometheus:v3.5.0 test rules kong-alerts_test.yaml
