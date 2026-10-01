#!/usr/bin/env bash
# Shows status for a backup job (the counterpart to restore-status.sh).
#
# Usage:
#   ./backup-status.sh <backup-job-id>              # one-shot
#   ./backup-status.sh <backup-job-id> --watch       # poll every 15s until terminal state
set -euo pipefail

JOB_ID="${1:?Usage: $0 <backup-job-id> [--watch]}"
WATCH=false
[ "${2:-}" = "--watch" ] && WATCH=true

show_status() {
  echo "=== Backup job: $JOB_ID ($(date '+%H:%M:%S')) ==="
  aws backup describe-backup-job --backup-job-id "$JOB_ID" \
    --query '{State:State,PercentDone:PercentDone,StatusMessage:StatusMessage,CreationDate:CreationDate,CompletionDate:CompletionDate}' \
    --output table
}

if [ "$WATCH" = false ]; then
  show_status
  exit 0
fi

while true; do
  clear
  show_status
  STATE=$(aws backup describe-backup-job --backup-job-id "$JOB_ID" --query 'State' --output text)
  case "$STATE" in
    COMPLETED|FAILED|ABORTED|EXPIRED|PARTIAL)
      echo
      echo "Final state: $STATE"
      break
      ;;
    *)
      sleep 15
      ;;
  esac
done
