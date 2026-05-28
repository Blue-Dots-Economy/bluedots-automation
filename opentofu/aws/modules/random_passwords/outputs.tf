output "keycloak_password" {
  description = "Generated Keycloak admin password"
  value       = random_password.keycloak.result
  sensitive   = true
}

output "postgresql_password" {
  description = "Generated PostgreSQL password"
  value       = random_password.postgresql.result
  sensitive   = true
}

output "redis_password" {
  description = "Generated Redis password"
  value       = random_password.redis.result
  sensitive   = true
}

output "encryption_string" {
  description = "Generated 32-char encryption string"
  value       = random_password.encryption_string.result
  sensitive   = true
}

output "random_string" {
  description = "Generated 12–24 char random string"
  value       = random_password.random_string.result
  sensitive   = true
}
