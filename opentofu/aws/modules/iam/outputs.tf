output "app_sa_role_arn" {
  description = "ARN of the application service account IAM role"
  value       = aws_iam_role.app_sa.arn
}

output "app_sa_role_name" {
  description = "Name of the application service account IAM role"
  value       = aws_iam_role.app_sa.name
}

output "signals_export_role_arn" {
  description = "ARN of the Signals S3-export IRSA role (null when signals_export_bucket is unset). Annotate onto the exporter ServiceAccount via s3-export.serviceAccount.annotations.\"eks.amazonaws.com/role-arn\"."
  value       = try(aws_iam_role.signals_export[0].arn, null)
}
