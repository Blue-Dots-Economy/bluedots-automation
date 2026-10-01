#!/usr/bin/env bash
# Triggers an on-demand AWS Backup job for THIS environment's EKS cluster, instead of
# waiting for the next scheduled (nightly/weekly) backup.
#
# Usage:
#   ./trigger-backup.sh                      # backs up this environment's cluster now
#   ./trigger-backup.sh --dry-run            # print the command without running it
#   ./trigger-backup.sh --retention-days 15  # override the lifecycle (default: this env's
#                                             # own backup_retention_days from global-values.yaml)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --retention-days) RETENTION_DAYS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

echo "Environment: $ENV_NAME ($REGION, account $ACCOUNT_ID)" >&2
echo >&2
echo "--- backup command ---" >&2
echo "aws backup start-backup-job \\" >&2
echo "  --backup-vault-name \"$VAULT_NAME\" \\" >&2
echo "  --resource-arn \"$CLUSTER_ARN\" \\" >&2
echo "  --iam-role-arn \"$BACKUP_ROLE_ARN\" \\" >&2
echo "  --lifecycle \"DeleteAfterDays=$RETENTION_DAYS\"" >&2
echo >&2

if [ "$DRY_RUN" = true ]; then
  echo "(dry run -- not executing)" >&2
  exit 0
fi

aws backup start-backup-job \
  --backup-vault-name "$VAULT_NAME" \
  --resource-arn "$CLUSTER_ARN" \
  --iam-role-arn "$BACKUP_ROLE_ARN" \
  --lifecycle "DeleteAfterDays=$RETENTION_DAYS"
