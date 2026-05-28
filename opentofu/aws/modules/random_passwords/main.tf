resource "random_password" "keycloak" {
  length           = var.keycloak_length
  special          = var.keycloak_special
  override_special = "!@#%&*()-_=+[]{}<>:?"
}

resource "random_password" "postgresql" {
  length  = var.postgresql_length
  special = var.postgresql_special
}

resource "random_password" "redis" {
  length  = var.redis_length
  special = var.redis_special
}

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
