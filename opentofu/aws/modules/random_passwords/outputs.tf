# ─── Common-services ────────────────────────────────────────────────────────
output "postgres_admin_password" {
  value     = random_id.postgres_admin_password.hex
  sensitive = true
}

# ─── Signals chart ──────────────────────────────────────────────────────────
output "signals_postgres_password" {
  value     = random_id.signals_postgres_password.hex
  sensitive = true
}

output "signals_export_ro_password" {
  value     = random_id.signals_export_ro_password.hex
  sensitive = true
}

output "signals_redis_password" {
  value     = random_id.signals_redis_password.hex
  sensitive = true
}

output "signals_auth_secret" {
  value     = random_id.signals_auth_secret.hex
  sensitive = true
}

# base64 of 32 random bytes == `openssl rand -base64 32`
output "signals_pii_key" {
  value     = random_id.signals_pii_key.b64_std
  sensitive = true
}

output "signals_notification_secret" {
  value     = random_id.signals_notification_secret.hex
  sensitive = true
}

output "signals_instance_shared_secret" {
  value     = random_id.signals_instance_shared_secret.hex
  sensitive = true
}

# ─── Aggregator chart ───────────────────────────────────────────────────────
output "aggregator_postgres_password" {
  value     = random_id.aggregator_postgres_password.hex
  sensitive = true
}

output "aggregator_kc_bootstrap_admin_password" {
  value     = random_id.aggregator_kc_bootstrap_admin_password.hex
  sensitive = true
}

output "aggregator_keycloak_admin_client_secret" {
  value     = random_id.aggregator_keycloak_admin_client_secret.hex
  sensitive = true
}

output "keycloak_postgres_password" {
  description = "Keycloak's own Postgres role password (credentials.keycloakPassword == secrets.keycloakPostgresPassword)"
  value       = random_id.keycloak_postgres_password.hex
  sensitive   = true
}

output "signals_api_client_secret" {
  description = "signals-api Keycloak client secret (keycloak secrets.signalsApiSecret == signals KEYCLOAK_API_CLIENT_SECRET)"
  value       = random_id.signals_api_client_secret.hex
  sensitive   = true
}

output "signalstack_client_secret" {
  description = "aggregator-dpg Keycloak service-client secret (Phase C service auth)"
  value       = random_id.signalstack_client_secret.hex
  sensitive   = true
}

output "voice_dpg_signals_secret" {
  description = "voice-dpg Keycloak service-client secret"
  value       = random_id.voice_dpg_signals_secret.hex
  sensitive   = true
}

output "campaign_manager_secret" {
  description = "campaign-manager Keycloak client secret (keycloak secrets.campaignManagerSecret)"
  value       = random_id.campaign_manager_secret.hex
  sensitive   = true
}

output "aggregator_approval_token_secret" {
  value     = random_id.aggregator_approval_token_secret.hex
  sensitive = true
}

output "aggregator_session_key" {
  value     = random_id.aggregator_session_key.hex
  sensitive = true
}

output "aggregator_oidc_client_secret" {
  value     = random_id.aggregator_oidc_client_secret.hex
  sensitive = true
}

# ─── Monitoring chart ───────────────────────────────────────────────────────
output "monitoring_grafana_password" {
  description = "Generated Grafana admin password"
  value       = random_password.monitoring_grafana_password.result
  sensitive   = true
}

# ─── Shared ─────────────────────────────────────────────────────────────────
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

output "signalstack_admin_key" {
  description = "Shared API key for aggregator.signalstackAdminKey AND signals AGGREGATOR_DPG_API_KEY"
  value       = random_password.signalstack_admin_key.result
  sensitive   = true
}

output "signals_search_api_key" {
  description = "API key the signals api sends to signals-search /v1/relevance (signals SIGNALS_SEARCH_API_KEY)"
  value       = random_password.signals_search_api_key.result
  sensitive   = true
}

output "raya_voice_bot_api_key" {
  description = "API key the raya voice bot sends to the signals api (signals RAYA_VOICE_BOT_API_KEY)"
  value       = random_password.raya_voice_bot_api_key.result
  sensitive   = true
}
