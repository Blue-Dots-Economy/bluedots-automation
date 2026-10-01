#!/usr/bin/env bash
# Triggers an AWS Backup EKS restore job from THIS environment's vault -- either a full
# cluster restore, or a namespace-scoped restore (up to 5 namespaces), onto an existing
# target cluster.
#
# Usage:
#   ./trigger-restore.sh --target-cluster NAME --az AZ [--namespaces ns1,ns2] \
#       [--recovery-point-arn ARN] [--source-kubeconfig PATH] [--dry-run]
#
# --target-cluster and --az are REQUIRED, always -- state explicitly which cluster you are
# restoring into and which Availability Zone its node(s) run in. Deliberately never
# defaulted or guessed: EBS volumes are AZ-locked, so restoring into the wrong AZ fails
# outright, and silently defaulting the target cluster is how you restore into the wrong
# place by accident.
#
# With no --recovery-point-arn, uses the latest composite recovery point in this
# environment's own vault.
# With no --namespaces, restores the FULL cluster (every backed-up PV).
# With --namespaces, cross-references the SOURCE cluster's LIVE PV->namespace mapping
# (via --source-kubeconfig, defaulting to $KUBECONFIG if exported) to restore only the
# volumes that actually belong to those namespaces -- AWS Backup's own recovery-point
# metadata only gives you the PV name, never which namespace it belonged to, so this has
# to be looked up on the live source cluster, not inferred from the backup alone.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TARGET_CLUSTER=""
AZ=""
NAMESPACES=""
RECOVERY_POINT_ARN=""
SOURCE_KUBECONFIG="${KUBECONFIG:-}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-cluster) TARGET_CLUSTER="$2"; shift 2 ;;
    --az) AZ="$2"; shift 2 ;;
    --namespaces) NAMESPACES="$2"; shift 2 ;;
    --recovery-point-arn) RECOVERY_POINT_ARN="$2"; shift 2 ;;
    --source-kubeconfig) SOURCE_KUBECONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$TARGET_CLUSTER" ]; then
  echo "Error: --target-cluster is required (which cluster to restore into)" >&2
  exit 1
fi
if [ -z "$AZ" ]; then
  echo "Error: --az is required (which Availability Zone the target cluster's node(s) run in -- EBS volumes are AZ-locked)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$RECOVERY_POINT_ARN" ]; then
  RECOVERY_POINT_ARN=$("$SCRIPT_DIR/list-recovery-points.sh" --latest)
  echo "Using latest recovery point: $RECOVERY_POINT_ARN" >&2
fi

CHILDREN=$(aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$VAULT_NAME" \
  --by-parent-recovery-point-arn "$RECOVERY_POINT_ARN" \
  --output json)

EBS_CHILDREN=$(echo "$CHILDREN" | jq '[.RecoveryPoints[] | select(.ResourceType == "EBS")]')

NS_JSON=""
if [ -n "$NAMESPACES" ]; then
  if [ -z "$SOURCE_KUBECONFIG" ]; then
    echo "Error: --namespaces requires --source-kubeconfig (or export KUBECONFIG) pointing at the SOURCE cluster, to look up which PVs belong to those namespaces" >&2
    exit 1
  fi
  echo "Resolving which volumes belong to namespace(s): $NAMESPACES (via $SOURCE_KUBECONFIG)" >&2
  IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"
  NS_JSON=$(printf '%s\n' "${NS_ARRAY[@]}" | jq -R . | jq -s -c .)

  VOLUME_NS_MAP=$(KUBECONFIG="$SOURCE_KUBECONFIG" kubectl get pv -o json | jq --argjson namespaces "$NS_JSON" '
    [.items[]
      | select(.spec.claimRef.namespace as $ns | $namespaces | index($ns))
      | {volumeId: .spec.csi.volumeHandle, namespace: .spec.claimRef.namespace}
    ]')

  MATCHED_IDS_JSON=$(echo "$VOLUME_NS_MAP" | jq -c '[.[].volumeId]')
  if [ "$(echo "$MATCHED_IDS_JSON" | jq 'length')" -eq 0 ]; then
    echo "Error: no PVs found on the source cluster for namespace(s) $NAMESPACES" >&2
    exit 1
  fi
  echo "$VOLUME_NS_MAP" | jq -r '.[] | "  \(.namespace): \(.volumeId)"' >&2

  SELECTED_EBS=$(echo "$EBS_CHILDREN" | jq --argjson ids "$MATCHED_IDS_JSON" \
    '[.[] | select(.ResourceArn as $arn | $ids | any(. as $id | $arn | endswith($id)))]')
else
  SELECTED_EBS="$EBS_CHILDREN"
fi

SELECTED_COUNT=$(echo "$SELECTED_EBS" | jq 'length')
if [ "$SELECTED_COUNT" -eq 0 ]; then
  echo "Error: no matching EBS volumes found to restore" >&2
  exit 1
fi
echo "Restoring $SELECTED_COUNT volume(s) into $TARGET_CLUSTER (AZ: $AZ)." >&2

NESTED_JOBS=$(echo "$SELECTED_EBS" | jq -r --arg az "$AZ" '
  [.[] | {key: .RecoveryPointArn, value: ({AvailabilityZone: $az} | tojson)}]
  | from_entries | tojson')

if [ -n "$NAMESPACES" ]; then
  METADATA=$(jq -n -r --arg cluster "$TARGET_CLUSTER" --arg nested "$NESTED_JOBS" --arg nsjson "$NS_JSON" '{
    clusterName: $cluster,
    newCluster: "false",
    namespaceLevelRestore: "true",
    namespaces: $nsjson,
    nestedRestoreJobs: $nested
  } | tojson')
else
  METADATA=$(jq -n -r --arg cluster "$TARGET_CLUSTER" --arg nested "$NESTED_JOBS" '{
    clusterName: $cluster,
    newCluster: "false",
    nestedRestoreJobs: $nested
  } | tojson')
fi

echo >&2
echo "--- restore command ---" >&2
printf 'aws backup start-restore-job \\\n  --recovery-point-arn "%s" \\\n  --iam-role-arn "%s" \\\n  --resource-type EKS \\\n  --metadata '"'"'%s'"'"'\n' \
  "$RECOVERY_POINT_ARN" "$RESTORE_ROLE_ARN" "$METADATA" >&2
echo >&2

if [ "$DRY_RUN" = true ]; then
  echo "(dry run -- not executing)" >&2
  exit 0
fi

aws backup start-restore-job \
  --recovery-point-arn "$RECOVERY_POINT_ARN" \
  --iam-role-arn "$RESTORE_ROLE_ARN" \
  --resource-type EKS \
  --metadata "$METADATA"
