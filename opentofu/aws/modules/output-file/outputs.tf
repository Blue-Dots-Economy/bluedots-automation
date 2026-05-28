output "common_services_values_path" {
  description = "Absolute path of the generated common-services-values.yaml file"
  value       = local_sensitive_file.common_services_values.filename
}

output "aggregator_values_path" {
  description = "Absolute path of the generated aggregator-values.yaml file"
  value       = local_sensitive_file.aggregator_values.filename
}

output "signals_values_path" {
  description = "Absolute path of the generated signals-values.yaml file"
  value       = local_sensitive_file.signals_values.filename
}
