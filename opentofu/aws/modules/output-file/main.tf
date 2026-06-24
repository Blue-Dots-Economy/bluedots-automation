locals {
  values_dir = "${var.base_location}/.."
}

# Single credential file for all charts — secrets only at ROOT level.
# Each chart reads this same file; helm ignores keys it doesn't recognise.
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
    signals_auth_secret                     = var.signals_auth_secret
    signals_pii_key                         = var.signals_pii_key
    signals_notification_secret             = var.signals_notification_secret
    signals_dpg_scoring_secret              = var.signals_dpg_scoring_secret
    signals_google_maps_api_key             = var.signals_google_maps_api_key
    notification_gmail_user                 = var.notification_gmail_user
    notification_gmail_pass                 = var.notification_gmail_pass
    notification_msg91_auth_key             = var.notification_msg91_auth_key
    notification_msg91_template_id          = var.notification_msg91_template_id
  })
}

# OpenTofu-generated non-secret values — cloud infra outputs (S3, IRSA) plus
# values computed from user inputs that plain YAML anchors can't express
# (list indexing, string join, path concatenation).
resource "local_sensitive_file" "global_cloud_values" {
  filename        = "${local.values_dir}/global-cloud-values.yaml"
  file_permission = "0600"
  content = templatefile("${path.module}/global-cloud-values.yaml.tfpl", {
    cloud_storage_region    = var.cloud_storage_region
    storage_bucket_public   = var.storage_bucket_public
    app_sa_role_arn         = var.app_sa_role_arn
    signals_public_hosts    = var.signals_public_hosts
    signals_allowed_origins = var.signals_allowed_origins
    signals_network         = var.signals_network
    signals_host_bindings   = var.signals_host_bindings
    postgres_host           = var.postgres_host
  })
}
