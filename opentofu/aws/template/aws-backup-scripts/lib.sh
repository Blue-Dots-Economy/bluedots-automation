# Shared environment resolution for the AWS Backup scripts in this directory.
# Sourced by every script here -- not meant to be run directly.
#
# Reads <env>/global-values.yaml (one directory up from this script) and derives the
# vault/role/cluster names using the exact same convention modules/backup and modules/eks
# use, so these scripts need zero per-environment editing after the template is copied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GLOBAL_VALUES="$ENV_DIR/global-values.yaml"

if [ ! -f "$GLOBAL_VALUES" ]; then
  echo "Error: $GLOBAL_VALUES not found." >&2
  echo "These scripts must live in <env>/aws-backup-scripts/, one level below that" >&2
  echo "environment's own global-values.yaml (i.e. copied here along with the rest of" >&2
  echo "opentofu/aws/template/ when the environment was created)." >&2
  exit 1
fi

_anchor_value() {
  grep -E "^_$1:" "$GLOBAL_VALUES" | sed -E "s/.*\&$1[[:space:]]+\"([^\"]*)\".*/\1/"
}

BUILDING_BLOCK="$(_anchor_value building_block)"
ENVIRONMENT="$(_anchor_value environment)"
REGION="$(_anchor_value cloud_storage_region)"

if [ -z "$BUILDING_BLOCK" ] || [ -z "$ENVIRONMENT" ] || [ -z "$REGION" ]; then
  echo "Error: couldn't read _building_block / _environment / _cloud_storage_region" >&2
  echo "anchors from $GLOBAL_VALUES -- has the file's top-of-file anchor format changed?" >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Same naming convention as modules/backup/main.tf (local.name) and modules/eks/main.tf
# (local.cluster_name) -- if either of those ever changes, update here too.
ENV_NAME="${BUILDING_BLOCK}-${ENVIRONMENT}"
VAULT_NAME="${ENV_NAME}-eks-backup-vault"
BACKUP_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ENV_NAME}-eks-backup-role"
RESTORE_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ENV_NAME}-eks-backup-restore-role"
CLUSTER_NAME="${ENV_NAME}-cluster"
CLUSTER_ARN="arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"

# The configured retention, if this environment has set one (global-values.yaml asserts no
# default for this on purpose -- see docs/eks-backup-plan or opentofu/CLAUDE.md). Empty if
# absent; scripts that use this should fall back sensibly rather than assume a number.
BACKUP_RETENTION_DAYS="$(grep -E '^[[:space:]]*backup_retention_days:' "$GLOBAL_VALUES" | sed -E 's/^[[:space:]]*backup_retention_days:[[:space:]]*([0-9]+).*/\1/' | head -1)"
