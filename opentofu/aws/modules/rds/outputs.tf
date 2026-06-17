# ---------------------------------------------------------------------------------------------------------------------
# Connection coordinates consumed by the output-file module (→ helm chart values).
# ---------------------------------------------------------------------------------------------------------------------

output "db_address" {
  description = "RDS endpoint hostname (no port). Feeds POSTGRES_HOST / dataPlatform.postgresHost."
  value       = aws_db_instance.this.address
}

output "db_endpoint" {
  description = "RDS endpoint as host:port."
  value       = aws_db_instance.this.endpoint
}

output "db_port" {
  description = "Port Postgres listens on."
  value       = aws_db_instance.this.port
}

output "db_instance_identifier" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "security_group_id" {
  description = "Security group ID attached to the RDS instance."
  value       = aws_security_group.rds.id
}
