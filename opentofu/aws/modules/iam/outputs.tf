# Annotated onto the aggregator api/worker AND the signals s3-export
# ServiceAccounts via eks.amazonaws.com/role-arn (see the output-file module).
output "app_sa_role_arn" {
  description = "ARN of the application service account IAM role"
  value       = aws_iam_role.app_sa.arn
}

output "app_sa_role_name" {
  description = "Name of the application service account IAM role"
  value       = aws_iam_role.app_sa.name
}
