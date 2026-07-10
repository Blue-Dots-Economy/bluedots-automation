# ─── Common-services postgres admin ─────────────────────────────────────────
resource "random_id" "postgres_admin_password" {
  byte_length = var.postgres_admin_password_bytes
}

# ─── Signals chart secrets ──────────────────────────────────────────────────
# All hex output via random_id.hex (length = 2 * byte_length).
resource "random_id" "signals_postgres_password" {
  byte_length = var.signals_postgres_password_bytes
}

resource "random_id" "signals_redis_password" {
  byte_length = var.signals_redis_password_bytes
}

resource "random_id" "signals_auth_secret" {
  byte_length = var.signals_auth_secret_bytes
}

# PII encryption key — base64 of 32 random bytes (equivalent to
# `openssl rand -base64 32`); exposed via the .b64_std output.
resource "random_id" "signals_pii_key" {
  byte_length = var.signals_pii_key_bytes
}

resource "random_id" "signals_notification_secret" {
  byte_length = var.signals_notification_secret_bytes
}

resource "random_id" "signals_dpg_scoring_secret" {
  byte_length = var.signals_dpg_scoring_secret_bytes
}

# Inter-instance peer-auth HMAC secret (INSTANCE_SHARED_SECRET). Min 32 chars;
# byte_length 32 → 64 hex chars. See signals-dpg#255.
resource "random_id" "signals_instance_shared_secret" {
  byte_length = var.signals_instance_shared_secret_bytes
}

# ─── Aggregator chart secrets ───────────────────────────────────────────────
resource "random_id" "aggregator_postgres_password" {
  byte_length = var.aggregator_postgres_password_bytes
}

resource "random_id" "aggregator_kc_bootstrap_admin_password" {
  byte_length = var.aggregator_kc_bootstrap_admin_password_bytes
}

resource "random_id" "aggregator_keycloak_admin_client_secret" {
  byte_length = var.aggregator_keycloak_admin_client_secret_bytes
}

resource "random_id" "aggregator_approval_token_secret" {
  byte_length = var.aggregator_approval_token_secret_bytes
}

resource "random_id" "aggregator_session_key" {
  byte_length = var.aggregator_session_key_bytes
}

resource "random_id" "aggregator_oidc_client_secret" {
  byte_length = var.aggregator_oidc_client_secret_bytes
}

# ─── Monitoring chart secrets ───────────────────────────────────────────────
resource "random_password" "monitoring_grafana_password" {
  length  = var.monitoring_grafana_password_length
  special = false
}

# ─── Shared application-layer secrets ───────────────────────────────────────
# 32-char encryption key used by application-layer field encryption.
resource "random_password" "encryption_string" {
  length  = var.encryption_string_length
  special = false
}

# 12–24 char shared random string used as a salt / token seed by the application.
resource "random_password" "random_string" {
  length  = var.random_string_length
  special = false
}

# Shared raw API key consumed by BOTH:
#   - aggregator helm chart: secrets.signalstackAdminKey
#   - signals helm chart:    api.apiconfig.data.AGGREGATOR_DPG_API_KEY
resource "random_password" "signalstack_admin_key" {
  length  = var.signalstack_admin_key_length
  special = false
}
