locals {
  values_dir = "${var.base_location}/.."
}

# One file per chart, each with values already at ROOT level so helm reads them
# via a single `-f` with no slicing/yq projection. Shared secrets are templated
# into each file directly (no cross-file YAML anchors needed).

# Single merged credential file for all charts. Holds secrets + infra outputs
# at ROOT level so each chart reads it via a single `-f`. Grown one chart at a
# time; non-secret config now lives in global-values.yaml / chart values.yaml.
resource "local_sensitive_file" "credential_values" {
  filename        = "${local.values_dir}/credential-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/credential-values.yaml.tfpl", {
    postgres_admin_password      = var.postgres_admin_password
    aggregator_postgres_password = var.aggregator_postgres_password
    signals_postgres_password    = var.signals_postgres_password
    signals_redis_password       = var.signals_redis_password
    monitoring_grafana_password  = var.monitoring_grafana_password
  })
}

resource "local_sensitive_file" "aggregator_values" {
  filename        = "${local.values_dir}/aggregator-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/aggregator-values.yaml.tfpl", {
    aggregator_host                         = var.aggregator_host
    aggregator_network                      = var.aggregator_network
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
    aggregator_smtp_user                    = var.aggregator_smtp_user
    aggregator_smtp_password                = var.aggregator_smtp_password
    aggregator_smtp_from                    = var.aggregator_smtp_from
    aggregator_admin_emails                 = var.aggregator_admin_emails
    aggregator_msg91_auth_key               = var.aggregator_msg91_auth_key
    aggregator_msg91_template_id            = var.aggregator_msg91_template_id
  })
}

resource "local_sensitive_file" "signals_values" {
  filename        = "${local.values_dir}/signals-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/signals-values.yaml.tfpl", {
    signals_public_hosts           = var.signals_public_hosts
    signals_host_bindings          = var.signals_host_bindings
    signals_network                = var.signals_network
    signals_served_domains         = var.signals_served_domains
    signals_allowed_origins        = var.signals_allowed_origins
    postgres_host                  = var.postgres_host
    signals_postgres_password      = var.signals_postgres_password
    signals_redis_password         = var.signals_redis_password
    signals_auth_secret            = var.signals_auth_secret
    signals_pii_key                = var.signals_pii_key
    signals_notification_secret    = var.signals_notification_secret
    signals_dpg_scoring_secret     = var.signals_dpg_scoring_secret
    signalstack_admin_key          = var.signalstack_admin_key
    signals_google_maps_api_key    = var.signals_google_maps_api_key
    notification_gmail_user        = var.notification_gmail_user
    notification_gmail_pass        = var.notification_gmail_pass
    notification_msg91_auth_key    = var.notification_msg91_auth_key
    notification_msg91_template_id = var.notification_msg91_template_id
  })
}
