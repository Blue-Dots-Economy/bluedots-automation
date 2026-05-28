output "global_cloud_values_path" {
  description = "Absolute path of the generated global-cloud-values.yaml file"
  value       = local_file.global_cloud_values.filename
}
