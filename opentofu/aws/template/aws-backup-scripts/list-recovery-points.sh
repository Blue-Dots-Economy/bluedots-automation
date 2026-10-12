#!/usr/bin/env bash
# Lists composite (whole-cluster) recovery points in THIS environment's backup vault,
# newest first.
#
# Usage:
#   ./list-recovery-points.sh                 # table of all composite recovery points
#   ./list-recovery-points.sh --latest        # prints just the newest ARN (for scripting)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LATEST_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --latest) LATEST_ONLY=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

RECOVERY_POINTS=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$VAULT_NAME" \
  --query "sort_by(RecoveryPoints[?contains(RecoveryPointArn, 'composite')], &CreationDate)" \
  --output json)

if [ "$LATEST_ONLY" = true ]; then
  echo "$RECOVERY_POINTS" | jq -r '.[-1].RecoveryPointArn'
  exit 0
fi

echo "$RECOVERY_POINTS" | jq -r '
  (["CREATED", "STATUS", "RECOVERY POINT ARN"] | @tsv),
  (.[] | [.CreationDate, .Status, .RecoveryPointArn] | @tsv)
' | column -t -s $'\t'
