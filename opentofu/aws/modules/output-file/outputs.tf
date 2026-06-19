output "credential_values_path" {
  description = "Absolute path of the generated credential-values.yaml file (shared by all charts)"
  value       = local_sensitive_file.credential_values.filename
}

output "aggregator_values_path" {
  description = "Absolute path of the generated aggregator-values.yaml file"
  value       = local_sensitive_file.aggregator_values.filename
}

output "signals_values_path" {
  description = "Absolute path of the generated signals-values.yaml file"
  value       = local_sensitive_file.signals_values.filename
}
