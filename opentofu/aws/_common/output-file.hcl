locals {
  global_vars            = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment            = local.global_vars.global.environment
  building_block         = local.global_vars.global.building_block
  cloud_storage_region   = local.global_vars.global.cloud_storage_region
  cloud_storage_provider = try(local.global_vars.global.cloud_storage_provider, "aws")
  aggregator_host        = try(local.global_vars.global.aggregator_host, "aggregator.servehalflife.com")

  # ── Signals hosts (host-routed served binding) ─────────────────────────────
  # signals_public_hosts is the SOLE source of the served hostnames (UI + /api).
  # List one host for a single domain, several for multi-domain — no legacy
  # single-host fallback. host_bindings maps each host to "<network>/<domain>".
  signals_public_hosts    = local.global_vars.global.signals_public_hosts
  signals_host_bindings   = try(local.global_vars.global.signals_host_bindings, "")
  # Network served by this deployment — shared by signals (NETWORK_CONFIG_LOCAL_FILE,
  # schema mount, VITE_NETWORK_NAME) AND aggregator (aggregatorNetwork).
  network                 = try(local.global_vars.global.network, "orange_dot")
  signals_served_domains  = try(local.global_vars.global.signals_served_domains, "orange_dot/tourist,orange_dot/practitioner")
  # CORS origins: localhost dev + https://<each served host>.
  signals_allowed_origins = join(",", concat(["http://localhost:8080", "http://127.0.0.1:8080"], [for h in local.signals_public_hosts : "https://${h}"]))
  signals_google_maps_api_key  = try(local.global_vars.global.signals_google_maps_api_key, "")
  notification_gmail_user      = try(local.global_vars.global.notification_gmail_user, "")
  notification_gmail_pass      = try(local.global_vars.global.notification_gmail_pass, "")
  notification_msg91_auth_key  = try(local.global_vars.global.notification_msg91_auth_key, "")
  notification_msg91_template_id = try(local.global_vars.global.notification_msg91_template_id, "")

  aggregator_smtp_user          = try(local.global_vars.global.aggregator_smtp_user, "")
  aggregator_smtp_password      = try(local.global_vars.global.aggregator_smtp_password, "")
  aggregator_smtp_from          = try(local.global_vars.global.aggregator_smtp_from, "")
  aggregator_admin_emails       = try(local.global_vars.global.aggregator_admin_emails, "")
  aggregator_msg91_auth_key     = try(local.global_vars.global.aggregator_msg91_auth_key, "")
  aggregator_msg91_template_id  = try(local.global_vars.global.aggregator_msg91_template_id, "")

}

terraform {
  source = "../../modules//output-file/"
}

dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id                = "vpc-dummy"
    vpc_cidr_block        = "10.0.0.0/16"
    public_subnet_ids     = ["subnet-dummy-1", "subnet-dummy-2"]
    private_subnet_ids    = []
    nat_gateway_public_ip = ""
  }
}

dependency "eks" {
  config_path                            = "../eks"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cluster_name                      = "dummy-cluster"
    cluster_endpoint                  = "https://dummy.eks.amazonaws.com"
    cluster_arn                       = "arn:aws:eks:us-east-1:123456789012:cluster/dummy"
    oidc_provider                     = "oidc.eks.us-east-1.amazonaws.com/id/DUMMY"
    oidc_provider_arn                 = "arn:aws:iam::123456789012:oidc-provider/dummy"
    node_role_arn                     = "arn:aws:iam::123456789012:role/dummy-node"
    private_lb_ip                     = ""
    cloudwatch_observability_role_arn = ""
  }
}

dependency "iam" {
  config_path                            = "../iam"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    app_sa_role_arn  = "arn:aws:iam::123456789012:role/dummy-app-sa"
    app_sa_role_name = "dummy-app-sa"
  }
}

dependency "storage" {
  config_path                            = "../storage"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    storage_bucket_public  = ""
    storage_bucket_private = ""
  }
}

dependency "random_passwords" {
  config_path                            = "../random_passwords"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    encryption_string     = "00000000000000000000000000000000"
    random_string         = "dummy-random-string-1234"
    signalstack_admin_key = "dummy-signalstack-admin-key-0000000000000000"

    postgres_admin_password = "0000000000000000000000000000000c"

    signals_postgres_password   = "00000000000000000000000000000001"
    signals_redis_password      = "00000000000000000000000000000002"
    signals_auth_secret         = "00000000000000000000000000000003"
    signals_pii_key             = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    signals_notification_secret = "00000000000000000000000000000004"
    signals_dpg_scoring_secret  = "0000000000000000000000000000000000000000000000000000000000000005"

    aggregator_postgres_password            = "0000000000000000000000000000000000000000000000000000000000000006"
    aggregator_kc_bootstrap_admin_password  = "0000000000000000000000000000000000000000000000000000000000000007"
    aggregator_keycloak_admin_client_secret = "0000000000000000000000000000000000000000000000000000000000000008"
    aggregator_approval_token_secret        = "0000000000000000000000000000000000000000000000000000000000000009"
    aggregator_session_key                  = "000000000000000000000000000000000000000000000000000000000000000a"
    aggregator_oidc_client_secret           = "000000000000000000000000000000000000000000000000000000000000000b"
    monitoring_grafana_password             = "dummy-grafana-password"
  }
}

inputs = {
  base_location          = get_terragrunt_dir()
  building_block         = local.building_block
  environment            = local.environment
  cloud_storage_provider = local.cloud_storage_provider
  cloud_storage_region   = local.cloud_storage_region
  aggregator_host        = local.aggregator_host
  aggregator_network     = local.network

  # Signals hosts (host-routed served binding)
  signals_public_hosts    = local.signals_public_hosts
  signals_host_bindings   = local.signals_host_bindings
  signals_network         = local.network
  signals_served_domains  = local.signals_served_domains
  signals_allowed_origins = local.signals_allowed_origins

  # Network
  vpc_id                = dependency.network.outputs.vpc_id
  vpc_cidr_block        = dependency.network.outputs.vpc_cidr_block
  public_subnet_ids     = dependency.network.outputs.public_subnet_ids
  private_subnet_ids    = dependency.network.outputs.private_subnet_ids
  nat_gateway_public_ip = dependency.network.outputs.nat_gateway_public_ip == null ? "" : dependency.network.outputs.nat_gateway_public_ip

  # EKS
  cluster_name                      = dependency.eks.outputs.cluster_name
  cluster_endpoint                  = dependency.eks.outputs.cluster_endpoint
  cluster_arn                       = dependency.eks.outputs.cluster_arn
  oidc_provider                     = dependency.eks.outputs.oidc_provider
  oidc_provider_arn                 = dependency.eks.outputs.oidc_provider_arn
  node_role_arn                     = dependency.eks.outputs.node_role_arn
  private_ingressgateway_ip         = dependency.eks.outputs.private_lb_ip == null ? "" : dependency.eks.outputs.private_lb_ip
  cloudwatch_observability_role_arn = dependency.eks.outputs.cloudwatch_observability_role_arn == null ? "" : dependency.eks.outputs.cloudwatch_observability_role_arn

  # IAM
  app_sa_role_arn  = dependency.iam.outputs.app_sa_role_arn
  app_sa_role_name = dependency.iam.outputs.app_sa_role_name

  # Storage
  storage_bucket_public  = dependency.storage.outputs.storage_bucket_public == null ? "" : dependency.storage.outputs.storage_bucket_public
  storage_bucket_private = dependency.storage.outputs.storage_bucket_private == null ? "" : dependency.storage.outputs.storage_bucket_private

  # Random secrets
  random_string         = dependency.random_passwords.outputs.random_string
  encryption_string     = dependency.random_passwords.outputs.encryption_string
  signalstack_admin_key = dependency.random_passwords.outputs.signalstack_admin_key

  postgres_admin_password = dependency.random_passwords.outputs.postgres_admin_password

  signals_postgres_password   = dependency.random_passwords.outputs.signals_postgres_password
  signals_redis_password      = dependency.random_passwords.outputs.signals_redis_password
  signals_auth_secret         = dependency.random_passwords.outputs.signals_auth_secret
  signals_pii_key             = dependency.random_passwords.outputs.signals_pii_key
  signals_notification_secret = dependency.random_passwords.outputs.signals_notification_secret
  signals_dpg_scoring_secret  = dependency.random_passwords.outputs.signals_dpg_scoring_secret

  aggregator_postgres_password            = dependency.random_passwords.outputs.aggregator_postgres_password
  aggregator_kc_bootstrap_admin_password  = dependency.random_passwords.outputs.aggregator_kc_bootstrap_admin_password
  aggregator_keycloak_admin_client_secret = dependency.random_passwords.outputs.aggregator_keycloak_admin_client_secret
  aggregator_approval_token_secret        = dependency.random_passwords.outputs.aggregator_approval_token_secret
  aggregator_session_key                  = dependency.random_passwords.outputs.aggregator_session_key
  aggregator_oidc_client_secret           = dependency.random_passwords.outputs.aggregator_oidc_client_secret

  signals_google_maps_api_key    = local.signals_google_maps_api_key
  notification_gmail_user        = local.notification_gmail_user
  notification_gmail_pass        = local.notification_gmail_pass
  notification_msg91_auth_key    = local.notification_msg91_auth_key
  notification_msg91_template_id = local.notification_msg91_template_id

  aggregator_smtp_user         = local.aggregator_smtp_user
  aggregator_smtp_password     = local.aggregator_smtp_password
  aggregator_smtp_from         = local.aggregator_smtp_from
  aggregator_admin_emails      = local.aggregator_admin_emails
  aggregator_msg91_auth_key    = local.aggregator_msg91_auth_key
  aggregator_msg91_template_id = local.aggregator_msg91_template_id

  monitoring_grafana_password = dependency.random_passwords.outputs.monitoring_grafana_password
}
