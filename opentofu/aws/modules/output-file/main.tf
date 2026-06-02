locals {
  values_dir = "${var.base_location}/.."
}

# One file per chart, each with values already at ROOT level so helm reads them
# via a single `-f` with no slicing/yq projection. Shared secrets are templated
# into each file directly (no cross-file YAML anchors needed).

resource "local_sensitive_file" "common_services_values" {
  filename        = "${local.values_dir}/common-services-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/common-services-values.yaml.tfpl", {
    postgres_admin_password      = var.postgres_admin_password
    aggregator_postgres_password = var.aggregator_postgres_password
    signals_postgres_password    = var.signals_postgres_password
    signals_redis_password       = var.signals_redis_password
  })
}

resource "local_sensitive_file" "aggregator_values" {
  filename        = "${local.values_dir}/aggregator-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/aggregator-values.yaml.tfpl", {
    aggregator_host                         = var.aggregator_host
    cloud_storage_region                    = var.cloud_storage_region
    storage_bucket_public                   = var.storage_bucket_public
    aggregator_postgres_password            = var.aggregator_postgres_password
    signals_redis_password                  = var.signals_redis_password
    aggregator_kc_bootstrap_admin_password  = var.aggregator_kc_bootstrap_admin_password
    aggregator_keycloak_admin_client_secret = var.aggregator_keycloak_admin_client_secret
    aggregator_approval_token_secret        = var.aggregator_approval_token_secret
    aggregator_session_key                  = var.aggregator_session_key
    aggregator_oidc_client_secret           = var.aggregator_oidc_client_secret
    signalstack_admin_key                   = var.signalstack_admin_key
    app_sa_role_arn                         = var.app_sa_role_arn
  })
}

resource "local_sensitive_file" "signals_values" {
  filename        = "${local.values_dir}/signals-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/signals-values.yaml.tfpl", {
    signals_host                = var.signals_host
    signals_ui_host             = var.signals_ui_host
    signals_postgres_password   = var.signals_postgres_password
    signals_redis_password      = var.signals_redis_password
    signals_auth_secret         = var.signals_auth_secret
    signals_pii_key             = var.signals_pii_key
    signals_notification_secret = var.signals_notification_secret
    signals_dpg_scoring_secret  = var.signals_dpg_scoring_secret
    signalstack_admin_key       = var.signalstack_admin_key
  })
}
