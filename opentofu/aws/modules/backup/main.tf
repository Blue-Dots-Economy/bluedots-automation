locals {
  environment_name = "${var.building_block}-${var.environment}"
  name             = "${local.environment_name}-eks-backup"

  # EKS cluster ARN's last path segment is the cluster name:
  # arn:aws:eks:<region>:<account>:cluster/<name> — used to prefix alert text so a message reads
  # "<cluster-name> BACKUP_JOB_FAILED" instead of a bare, unattributed event name.
  cluster_name = split("/", var.eks_cluster_arn)[1]

  # AWS Backup's own BackupJobState / RestoreJobState enum. PARTIAL is a distinct state, not a
  # flavor of COMPLETED — included deliberately: an EKS backup can finish Partial / Completed with
  # issues when an individual PV child job fails, and that reads as success on a dashboard unless
  # it's alerted on explicitly. This list is written from the documented API enum, not a
  # live-observed event — confirm PARTIAL is really what a "Completed with issues" job reports
  # before relying on it.
  backup_job_alert_states  = ["COMPLETED", "FAILED", "PARTIAL", "ABORTED", "EXPIRED"]
  restore_job_alert_states = ["COMPLETED", "FAILED", "ABORTED"]

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

# ---------------------------------------------------------------------------------------------------------------------
# Notifications — a silent backup is not a backup. Routed through EventBridge rather than
# aws_backup_vault_notifications: that resource's backup_vault_events is a fixed AWS enum
# (BACKUP_JOB_FAILED, ...) with no way to say WHICH cluster it's about. AWS Backup emits the same
# underlying job state-change events to the default EventBridge bus automatically (no extra
# enablement needed) — this intercepts them and reformats the message as
# "<cluster-name> BACKUP_JOB_<STATE>" / "<cluster-name> RESTORE_JOB_<STATE>" before it reaches SNS.
# ---------------------------------------------------------------------------------------------------------------------

#trivy:ignore:AWS-0136 -- Trivy wants a customer-managed key here, but this account's deploying
# identity has kms:PutKeyPolicy permanently denied (see aws_kms_key.backup above), so no CMK with
# a custom policy can ever be created by it — any explicit key policy fails CreateKey outright,
# not just this SNS grant. alias/aws/sns (AWS-managed) still gives real encryption at rest and
# ships already trusting the SNS service, satisfying AWS-0095 without requiring a policy we can't
# create. Messages here carry no secrets/PII — just alert text like "<cluster> BACKUP_JOB_FAILED".
resource "aws_sns_topic" "backup_alerts" {
  name = "${local.name}-alerts"

  kms_master_key_id = "alias/aws/sns"

  tags = local.common_tags
}

resource "aws_sns_topic_policy" "backup_alerts" {
  arn = aws_sns_topic.backup_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "SNS:Publish"
      Resource  = aws_sns_topic.backup_alerts.arn
    }]
  })
}

# Each subscription needs a human to click the confirmation link — Terraform can create the
# pending subscription but can't complete it.
resource "aws_sns_topic_subscription" "backup_alerts_email" {
  for_each  = toset(var.backup_alert_emails)
  topic_arn = aws_sns_topic.backup_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_event_rule" "backup_job_state_change" {
  name = "${local.name}-backup-job-state-change"

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Backup Job State Change"]
    detail = {
      backupVaultName = [aws_backup_vault.eks.name]
      state           = local.backup_job_alert_states
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "backup_job_state_change" {
  rule = aws_cloudwatch_event_rule.backup_job_state_change.name
  arn  = aws_sns_topic.backup_alerts.arn

  input_transformer {
    input_paths = {
      state = "$.detail.state"
      job   = "$.detail.backupJobId"
    }
    input_template = "\"${local.cluster_name} BACKUP_JOB_<state> (job <job>)\""
  }

  depends_on = [aws_sns_topic_policy.backup_alerts]
}

# Restore Job State Change events aren't reliably scoped by backupVaultName (a restore can target
# a different destination than its source vault), so this filters on resourceType instead — the
# field AWS Backup's EventBridge events use consistently across job types to say what kind of
# resource the job is for.
resource "aws_cloudwatch_event_rule" "restore_job_state_change" {
  name = "${local.name}-restore-job-state-change"

  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Restore Job State Change"]
    detail = {
      resourceType = ["EKS"]
      state        = local.restore_job_alert_states
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "restore_job_state_change" {
  rule = aws_cloudwatch_event_rule.restore_job_state_change.name
  arn  = aws_sns_topic.backup_alerts.arn

  input_transformer {
    input_paths = {
      state = "$.detail.state"
      job   = "$.detail.restoreJobId"
    }
    input_template = "\"${local.cluster_name} RESTORE_JOB_<state> (job <job>)\""
  }

  depends_on = [aws_sns_topic_policy.backup_alerts]
}
