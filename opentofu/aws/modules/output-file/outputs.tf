output "global_credentials_path" {
  description = "Absolute path of the generated global-credentials.yaml file (shared by all charts)"
  value       = local_sensitive_file.global_credentials.filename
}

output "global_cloud_values_path" {
  description = "Absolute path of the generated global-cloud-values.yaml file (S3 + IRSA ARN)"
  value       = local_sensitive_file.global_cloud_values.filename
}

output "signals_values_path" {
  description = "Absolute path of the generated signals-values.yaml file"
  value       = local_sensitive_file.signals_values.filename
}
