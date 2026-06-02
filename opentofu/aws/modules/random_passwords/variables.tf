# Lengths below are in BYTES for random_id (hex output = 2 * byte_length chars).
# i.e. `openssl rand -hex 16` ≡ byte_length = 16 → 32 hex chars.

# -----------------------------------------------------------------------------
# Common-services (shared postgres + redis StatefulSets) secrets
# -----------------------------------------------------------------------------
variable "postgres_admin_password_bytes" {
  type    = number
  default = 16
}

# -----------------------------------------------------------------------------
# Signals chart secrets
# -----------------------------------------------------------------------------
variable "signals_postgres_password_bytes" {
  type    = number
  default = 16
}

variable "signals_redis_password_bytes" {
  type    = number
  default = 16
}

variable "signals_auth_secret_bytes" {
  type    = number
  default = 32
}

variable "signals_notification_secret_bytes" {
  type    = number
  default = 32
}

variable "signals_dpg_scoring_secret_bytes" {
  type    = number
  default = 32
}

# -----------------------------------------------------------------------------
# Aggregator chart secrets
# -----------------------------------------------------------------------------
variable "aggregator_postgres_password_bytes" {
  type    = number
  default = 16
}

variable "aggregator_kc_bootstrap_admin_password_bytes" {
  type    = number
  default = 16
}

variable "aggregator_keycloak_admin_client_secret_bytes" {
  type    = number
  default = 32
}

variable "aggregator_approval_token_secret_bytes" {
  type    = number
  default = 32
}

variable "aggregator_session_key_bytes" {
  type    = number
  default = 32
}

variable "aggregator_oidc_client_secret_bytes" {
  type    = number
  default = 32
}

# -----------------------------------------------------------------------------
# Shared / application-layer secrets
# -----------------------------------------------------------------------------
variable "encryption_string_length" {
  type        = number
  description = "Length of the generated encryption string (must be 32)"
  default     = 32
  validation {
    condition     = var.encryption_string_length == 32
    error_message = "encryption_string_length must be exactly 32."
  }
}

variable "random_string_length" {
  type        = number
  description = "Length of the generated app random/secret string (12–24)"
  default     = 24
  validation {
    condition     = var.random_string_length >= 12 && var.random_string_length <= 24
    error_message = "random_string_length must be between 12 and 24."
  }
}

variable "signalstack_admin_key_length" {
  type        = number
  description = "Length of the shared signals-DPG admin api key (aggregator.signalstackAdminKey == signals AGGREGATOR_DPG_API_KEY). Must be >= 32."
  default     = 48
  validation {
    condition     = var.signalstack_admin_key_length >= 32
    error_message = "signalstack_admin_key_length must be at least 32."
  }
}
