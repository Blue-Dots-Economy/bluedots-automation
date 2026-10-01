locals {
  environment_name = "${var.building_block}-${var.environment}"
  name             = "${local.environment_name}-eks-backup"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  # Same permissions-boundary composition as modules/iam — account id and partition come from the
  # caller so one name works in every account/partition. Empty/null = argument omitted.
  permissions_boundary = var.permissions_boundary_policy_name != null && var.permissions_boundary_policy_name != "" ? format(
    "arn:%s:iam::%s:policy/%s",
    data.aws_partition.current.partition,
    data.aws_caller_identity.current.account_id,
    var.permissions_boundary_policy_name,
  ) : null

  backup_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:backup:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------------------------------------------------
# IAM — two roles, deliberately kept apart.
#
# `eks_backup` is what the nightly job actually runs as: backup-only permissions, nothing else.
# `eks_restore` carries the elevated policy and is NEVER referenced by the plan/selection below —
# it exists purely to be assumed by hand when an actual restore is being performed.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "eks_backup" {
  name                 = "${local.name}-role"
  permissions_boundary = local.permissions_boundary
  assume_role_policy   = local.backup_assume_role_policy

  tags = merge(local.common_tags, { Name = "${local.name}-role" })
}

resource "aws_iam_role_policy_attachment" "eks_backup" {
  role       = aws_iam_role.eks_backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Only needed if an S3-backed PVC (not EBS) is actually in scope — not the case for any cluster
# checked so far.
resource "aws_iam_role_policy_attachment" "eks_backup_s3" {
  count      = var.backup_enable_s3 ? 1 : 0
  role       = aws_iam_role.eks_backup.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForS3Backup"
}

resource "aws_iam_role" "eks_restore" {
  name                 = "${local.name}-restore-role"
  permissions_boundary = local.permissions_boundary
  assume_role_policy   = local.backup_assume_role_policy

  tags = merge(local.common_tags, { Name = "${local.name}-restore-role" })
}

resource "aws_iam_role_policy_attachment" "eks_restore" {
  role       = aws_iam_role.eks_restore.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# No second attachment for EKS-specific restore access: "AWSBackupFullAccessPolicyForRestore" is
# not an IAM managed policy (arn:aws:iam::aws:policy/... 404s — confirmed on a real apply) — it's
# an EKS cluster access policy (arn:aws:eks::aws:cluster-access-policy/...), a different mechanism
# entirely, granted via an EKS access entry. AWS's own "Restore an Amazon EKS cluster" doc lists
# only AWSBackupServiceRolePolicyForRestores (above) as required for the restore role, and states
# AWS Backup creates the access entries it needs itself during the restore job — the prerequisite
# is authentication_mode = "API_AND_CONFIG_MAP" on the cluster (already set in modules/eks), not
# anything pre-attached to this role.

# ---------------------------------------------------------------------------------------------------------------------
# KMS — customer-managed key encrypting the vault. Rotation on; deletion window gives a recovery
# buffer if the key is ever targeted for deletion by mistake.
#
# Deliberately no explicit `policy` argument — same as modules/eks's aws_kms_key.eks_secrets. Some
# deploying accounts permanently deny kms:PutKeyPolicy to the automation identity as a guardrail
# (so that identity can never rewrite a key's resource policy to grant itself broader access), in
# which case ANY explicit policy — including one that's functionally identical to AWS's own
# default — fails CreateKey with "the new key policy will not allow you to update the key policy
# in the future". Omitting the argument lets AWS attach its own default (root-only) policy, which
# isn't sent as an explicit API parameter and so isn't subject to that check. AWS Backup itself
# doesn't need a key-policy grant either — it uses kms:CreateGrant, a different, commonly-allowed
# mechanism.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_kms_key" "backup" {
  description             = "${local.name} vault encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = local.common_tags
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.backup.key_id
}

# ---------------------------------------------------------------------------------------------------------------------
# Vault + lock — GOVERNANCE mode. Omitting `changeable_for_days` is what selects governance over
# compliance mode: setting it, to any value, makes the vault immutable — by anyone, including
# account root and AWS Support — after a 72-hour cooling-off period. Do not add that argument.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_backup_vault" "eks" {
  name        = "${local.name}-vault"
  kms_key_arn = aws_kms_key.backup.arn

  tags = local.common_tags
}

resource "aws_backup_vault_lock_configuration" "eks" {
  backup_vault_name = aws_backup_vault.eks.name

  min_retention_days = var.backup_min_retention_days
  max_retention_days = var.backup_max_retention_days

  lifecycle {
    precondition {
      condition     = var.backup_min_retention_days <= var.backup_retention_days && var.backup_retention_days <= var.backup_max_retention_days
      error_message = "backup_retention_days (${var.backup_retention_days}) must sit between backup_min_retention_days (${var.backup_min_retention_days}) and backup_max_retention_days (${var.backup_max_retention_days}) — otherwise every backup job fails against this vault's lock. Fix the values in global-values.yaml."
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Backup plan — one rule, schedule/retention entirely driven by global-values.yaml so the same
# module serves a daily-prod / weekly-dev/UAT split without forking. No cold_storage_after: AWS
# requires delete_after >= cold_storage_after + 90, which no retention value under discussion for
# this fleet clears — warm storage only.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_backup_plan" "eks" {
  name = local.name

  rule {
    rule_name         = "${local.name}-rule"
    target_vault_name = aws_backup_vault.eks.name
    schedule          = var.backup_schedule
    start_window      = var.backup_start_window
    completion_window = var.backup_completion_window

    lifecycle {
      delete_after = var.backup_retention_days
      # No cold_storage_after — see comment above.
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = var.backup_retention_days > 0 && var.backup_schedule != ""
      error_message = "backup_schedule and backup_retention_days must both be set explicitly in global-values.yaml before backup_enabled is turned on — there is no default."
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Selection — the explicit cluster ARN, not a tag selector, so tagging something elsewhere can
# never silently widen or narrow what's protected.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_backup_selection" "eks" {
  name         = "${local.name}-selection"
  iam_role_arn = aws_iam_role.eks_backup.arn
  plan_id      = aws_backup_plan.eks.id
  resources    = [var.eks_cluster_arn]
}
