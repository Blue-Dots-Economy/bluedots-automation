variable "environment" {
  description = "Environment name"
  type        = string
}

variable "building_block" {
  description = "Building block name (naming prefix)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

# ---------------------------------------------------------------------------------------------------------------------
# Target
# ---------------------------------------------------------------------------------------------------------------------

variable "eks_cluster_arn" {
  description = "ARN of the EKS cluster to protect. Explicit ARN, not a tag selector, so adding a tag elsewhere can never silently widen or narrow what this plan backs up."
  type        = string
}

variable "permissions_boundary_policy_name" {
  description = <<-EOT
    Name of an IAM policy in THIS account to attach as the permissions boundary on the roles this
    module creates. Empty (or null) attaches none — the right answer for any account that does
    not gate role creation on a boundary. See modules/iam/variables.tf for the full rationale;
    repeated here rather than depended on so this module has no dependency on the iam module.
  EOT
  type        = string
  default     = null
  nullable    = true
}

# ---------------------------------------------------------------------------------------------------------------------
# Schedule / retention — no defaults asserted here on purpose. Prod and dev/UAT cadence and
# retention differ, so the module itself takes no position; set explicitly per environment in
# global-values.yaml.
# ---------------------------------------------------------------------------------------------------------------------

variable "backup_schedule" {
  description = "AWS Backup cron schedule (UTC), e.g. \"cron(30 18 ? * * *)\" for 00:00 IST daily. Frequency is a variable so one module serves both a daily-prod and weekly-dev/UAT cadence without forking."
  type        = string
}

variable "backup_retention_days" {
  description = "Days to retain each EKS recovery point (the plan rule's delete_after). Must sit between backup_min_retention_days and backup_max_retention_days or every backup job fails against the vault lock."
  type        = number
}

variable "backup_min_retention_days" {
  description = "Vault lock floor — the minimum delete_after any plan against this vault may set."
  type        = number
  default     = 7
}

variable "backup_max_retention_days" {
  description = "Vault lock ceiling — the maximum delete_after any plan against this vault may set."
  type        = number
  default     = 35
}

variable "backup_start_window" {
  description = "Minutes AWS Backup waits for the job to start before marking it failed."
  type        = number
  default     = 60
}

variable "backup_completion_window" {
  description = "Minutes AWS Backup waits for a running job to finish before marking it failed."
  type        = number
  default     = 300
}

# ---------------------------------------------------------------------------------------------------------------------
# Notifications / optional extras
# ---------------------------------------------------------------------------------------------------------------------

variable "backup_alert_emails" {
  description = "Email addresses subscribed to backup/restore job events (BACKUP_JOB_FAILED, BACKUP_JOB_COMPLETED, RESTORE_JOB_FAILED, RESTORE_JOB_COMPLETED). Each subscription needs a manual click to confirm — Terraform can't complete that step."
  type        = list(string)
  default     = []
}

variable "backup_enable_s3" {
  description = "Attach AWSBackupServiceRolePolicyForS3Backup to the backup role. Leave false unless an S3-backed PVC (not EBS) is actually in scope for this cluster."
  type        = bool
  default     = false
}
