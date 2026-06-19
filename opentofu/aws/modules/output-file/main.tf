locals {
  values_dir = "${var.base_location}/.."
}

# Single credential file for all charts — secrets only at ROOT level.
# Each chart reads this same file; helm ignores keys it doesn't recognise.
# Grown one chart at a time; non-secret config lives in global-values.yaml.
resource "local_sensitive_file" "global_credentials" {
  filename        = "${local.values_dir}/global-credentials.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/global-credentials.yaml.tfpl", {
    postgres_admin_password                 = var.postgres_admin_password
    aggregator_postgres_password            = var.aggregator_postgres_password
    signals_postgres_password               = var.signals_postgres_password
    signals_redis_password                  = var.signals_redis_password
    monitoring_grafana_password             = var.monitoring_grafana_password
    aggregator_kc_bootstrap_admin_password  = var.aggregator_kc_bootstrap_admin_password
    aggregator_keycloak_admin_client_secret = var.aggregator_keycloak_admin_client_secret
    aggregator_approval_token_secret        = var.aggregator_approval_token_secret
    aggregator_session_key                  = var.aggregator_session_key
    aggregator_oidc_client_secret           = var.aggregator_oidc_client_secret
    signalstack_admin_key                   = var.signalstack_admin_key
    aggregator_smtp_user                    = var.aggregator_smtp_user
    aggregator_smtp_password                = var.aggregator_smtp_password
    aggregator_msg91_auth_key               = var.aggregator_msg91_auth_key
  })
}

# Cloud infra outputs — S3 bucket/region and IRSA ARN. Generated (depends on
# provisioned resources), so kept separate from user-edited global-values.yaml.
resource "local_sensitive_file" "global_cloud_values" {
  filename        = "${local.values_dir}/global-cloud-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/global-cloud-values.yaml.tfpl", {
    cloud_storage_region  = var.cloud_storage_region
    storage_bucket_public = var.storage_bucket_public
    app_sa_role_arn       = var.app_sa_role_arn
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
