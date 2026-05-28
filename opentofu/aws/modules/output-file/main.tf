locals {
  global_cloud_values_file = "${var.base_location}/../global-cloud-values.yaml"
}

resource "local_sensitive_file" "global_cloud_values_yaml" {
  filename        = local.global_cloud_values_file
  file_permission = "0600"
  content = templatefile("${path.module}/global-cloud-values.yaml.tfpl", {
    building_block                    = var.building_block
    environment                       = var.environment
    cloud_storage_provider            = var.cloud_storage_provider
    cloud_storage_region              = var.cloud_storage_region
    vpc_id                            = var.vpc_id
    vpc_cidr_block                    = var.vpc_cidr_block
    public_subnet_ids_json            = jsonencode(var.public_subnet_ids)
    private_subnet_ids_json           = jsonencode(var.private_subnet_ids)
    nat_gateway_public_ip             = var.nat_gateway_public_ip
    cluster_name                      = var.cluster_name
    cluster_endpoint                  = var.cluster_endpoint
    cluster_arn                       = var.cluster_arn
    oidc_provider                     = var.oidc_provider
    oidc_provider_arn                 = var.oidc_provider_arn
    node_role_arn                     = var.node_role_arn
    private_ingressgateway_ip         = var.private_ingressgateway_ip
    cloudwatch_observability_role_arn = var.cloudwatch_observability_role_arn
    app_sa_role_arn                   = var.app_sa_role_arn
    app_sa_role_name                  = var.app_sa_role_name
    storage_bucket_public             = var.storage_bucket_public
    storage_bucket_private            = var.storage_bucket_private
    random_string                     = var.random_string
    encryption_string                 = var.encryption_string
    signalstack_admin_key             = var.signalstack_admin_key

    signals_postgres_password   = var.signals_postgres_password
    signals_redis_password      = var.signals_redis_password
    signals_auth_secret         = var.signals_auth_secret
    signals_notification_secret = var.signals_notification_secret
    signals_dpg_scoring_secret  = var.signals_dpg_scoring_secret

    aggregator_postgres_password            = var.aggregator_postgres_password
    aggregator_kc_bootstrap_admin_password  = var.aggregator_kc_bootstrap_admin_password
    aggregator_keycloak_admin_client_secret = var.aggregator_keycloak_admin_client_secret
    aggregator_approval_token_secret        = var.aggregator_approval_token_secret
    aggregator_session_key                  = var.aggregator_session_key
    aggregator_oidc_client_secret           = var.aggregator_oidc_client_secret
  })
}
