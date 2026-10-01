#!/usr/bin/env bash
# Shows status for a restore job, including its nested per-volume/per-resource child jobs
# (same info the AWS Backup console's "Nested restore jobs" table shows, in one call).
#
# Usage:
#   ./restore-status.sh <restore-job-id>              # one-shot
#   ./restore-status.sh <restore-job-id> --watch       # poll every 15s until terminal state
set -euo pipefail

JOB_ID="${1:?Usage: $0 <restore-job-id> [--watch]}"
WATCH=false
[ "${2:-}" = "--watch" ] && WATCH=true

show_status() {
  echo "=== Parent job: $JOB_ID ($(date '+%H:%M:%S')) ==="
  aws backup describe-restore-job --restore-job-id "$JOB_ID" \
    --query '{Status:Status,PercentDone:PercentDone,StatusMessage:StatusMessage,CreationDate:CreationDate,CompletionDate:CompletionDate}' \
    --output table

  echo
  echo "=== Nested jobs ==="
  aws backup list-restore-jobs --by-parent-job-id "$JOB_ID" \
    --query 'RestoreJobs[].{Resource:ResourceType,Status:Status,PercentDone:PercentDone,StatusMessage:StatusMessage}' \
    --output table
}

if [ "$WATCH" = false ]; then
  show_status
  exit 0
fi

while true; do
  clear
  show_status
  STATUS=$(aws backup describe-restore-job --restore-job-id "$JOB_ID" --query 'Status' --output text)
  case "$STATUS" in
    COMPLETED|FAILED|ABORTED)
      echo
      echo "Final status: $STATUS"
      break
      ;;
    *)
      sleep 15
      ;;
  esac
done
