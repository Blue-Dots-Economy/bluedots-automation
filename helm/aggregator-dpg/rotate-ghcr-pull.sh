#!/usr/bin/env bash
# rotate-ghcr-pull.sh — rotate the ghcr-pull image-pull secret across stacks.
#
# The ghcr-pull Secret is created out-of-band (NOT Helm-managed); both umbrella
# charts reference it by name with imagePullSecret.create=false. Rotating it is
# therefore decoupled from helm upgrades — just re-apply the Secret here.
#
# Usage:
#   ./rotate-ghcr-pull.sh <NEW_PAT>
#   PAT prompt (off shell history):  ./rotate-ghcr-pull.sh
#
# After rotation, revoke the OLD PAT in GitHub once image pulls succeed.
set -euo pipefail

USER="vinodbhorge"
SERVER="ghcr.io"
NAMESPACES=(signal-stack aggregator)

PAT="${1:-}"
if [[ -z "$PAT" ]]; then
  read -rsp "New GHCR PAT (read:packages): " PAT; echo
fi
[[ -n "$PAT" ]] || { echo "error: empty PAT" >&2; exit 1; }

for NS in "${NAMESPACES[@]}"; do
  echo "==> updating ghcr-pull in $NS"
  kubectl create secret docker-registry ghcr-pull \
    --docker-server="$SERVER" \
    --docker-username="$USER" \
    --docker-password="$PAT" \
    -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
done

echo "==> verify"
for NS in "${NAMESPACES[@]}"; do
  GOT=$(kubectl -n "$NS" get secret ghcr-pull \
        -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
        | grep -o '"password":"[^"]*"' || true)
  echo "  $NS: ${GOT:-<not found>}"
done

echo
echo "Done. New PAT is live. Revoke the OLD PAT in GitHub once pulls succeed."
echo "Force a fresh pull on a node if needed:"
echo "  kubectl -n <ns> rollout restart deploy/<name>"
