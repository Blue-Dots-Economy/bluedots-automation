#!/usr/bin/env bash
# Verifies pod and PVC health across namespaces on the CURRENT kubeconfig context.
# Run this against the RESTORE TARGET cluster after a restore job completes.
#
# Usage:
#   export KUBECONFIG=/path/to/target-cluster-kubeconfig.yaml
#   ./verify-restore.sh                      # checks every namespace
#   ./verify-restore.sh monitoring signals   # checks only the namespaces listed
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found on PATH." >&2
  exit 1
fi

NAMESPACES=("$@")
if [ ${#NAMESPACES[@]} -eq 0 ]; then
  mapfile -t NAMESPACES < <(kubectl get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
fi

echo "Context: $(kubectl config current-context)"
echo "Namespaces checked: ${NAMESPACES[*]}"
echo

total_issues=0

for ns in "${NAMESPACES[@]}"; do
  pod_json=$(kubectl get pods -n "$ns" -o json)
  pod_count=$(echo "$pod_json" | jq '.items | length')

  not_running=$(echo "$pod_json" | jq -r '.items[] | select(.status.phase != "Running") | .metadata.name')
  not_ready=$(echo "$pod_json" | jq -r '.items[] | select(([.status.containerStatuses[]?.ready] | all) | not) | .metadata.name')
  restarting=$(echo "$pod_json" | jq -r '.items[] | select(([.status.containerStatuses[]?.restartCount // 0] | add) > 0) | "\(.metadata.name) (\([.status.containerStatuses[]?.restartCount // 0] | add) restarts)"')

  pvc_json=$(kubectl get pvc -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
  pvc_count=$(echo "$pvc_json" | jq '.items | length')
  pvc_unbound=$(echo "$pvc_json" | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name')

  ns_issues=0
  echo "=== $ns ($pod_count pods, $pvc_count pvcs) ==="

  if [ -n "$not_running" ]; then
    echo "  NOT RUNNING:   $not_running"
    ns_issues=1
  fi
  if [ -n "$not_ready" ]; then
    echo "  NOT READY:     $not_ready"
    ns_issues=1
  fi
  if [ -n "$pvc_unbound" ]; then
    echo "  PVC NOT BOUND: $pvc_unbound"
    ns_issues=1
  fi
  if [ -n "$restarting" ]; then
    echo "  restarts (informational, not a failure): $restarting"
  fi

  if [ "$pod_count" -eq 0 ] && [ "$pvc_count" -eq 0 ]; then
    echo "  (empty namespace)"
  elif [ "$ns_issues" -eq 0 ]; then
    echo "  OK"
  else
    echo "  --- recent warning events ---"
    kubectl get events -n "$ns" --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -10 | sed 's/^/  /'
  fi

  total_issues=$((total_issues + ns_issues))
  echo
done

if [ "$total_issues" -eq 0 ]; then
  echo "All namespaces healthy."
  exit 0
else
  echo "$total_issues namespace(s) have issues -- see above."
  exit 1
fi
