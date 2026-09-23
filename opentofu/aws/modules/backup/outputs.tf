output "vault_name" {
  description = "Name of the AWS Backup vault"
  value       = aws_backup_vault.eks.name
}

output "vault_arn" {
  description = "ARN of the AWS Backup vault"
  value       = aws_backup_vault.eks.arn
}

output "plan_id" {
  description = "ID of the AWS Backup plan"
  value       = aws_backup_plan.eks.id
}

output "backup_role_arn" {
  description = "IAM role ARN AWS Backup assumes to run the nightly job (backup-only permissions)."
  value       = aws_iam_role.eks_backup.arn
}

output "restore_role_arn" {
  description = "IAM role ARN to assume manually when actually performing a restore. Never used by the automated plan/selection — carries the elevated, cluster-admin-equivalent restore policy."
  value       = aws_iam_role.eks_restore.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN that backup/restore job events are published to."
  value       = aws_sns_topic.backup_alerts.arn
}
