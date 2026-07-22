locals {
  global_vars          = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  cloud_storage_region = local.global_vars.global.cloud_storage_region

  # ── Signals hosts (host-routed served binding) ─────────────────────────────
  # signals_public_hosts is the SOLE source of the served hostnames (UI + /api).
  # List one host for a single domain, several for multi-domain — no legacy
  # single-host fallback. host_bindings maps each host to "<network>/<domain>".
  signals_public_hosts  = local.global_vars.global.signals_public_hosts
  signals_host_bindings = try(local.global_vars.global.signals_host_bindings, "")
  # Network served by this deployment — shared by signals (NETWORK_CONFIG_LOCAL_FILE,
  # schema mount, VITE_NETWORK_NAME) AND aggregator (aggregatorNetwork).
  network = try(local.global_vars.global.network, "orange_dot")
  # CORS origins: localhost dev + https://<each served host>.
  signals_allowed_origins = join(",", concat(["http://localhost:8080", "http://127.0.0.1:8080"], [for h in local.signals_public_hosts : "https://${h}"]))
  # notification_gmail_pass, notification_msg91_auth_key, notification_msg91_template_id,
  # aggregator_smtp_password, aggregator_msg91_auth_key, and signals_google_maps_api_key are
  # no longer read from global-values.yaml — global-secrets.yaml.tfpl bakes in
  # "UPDATE_THIS_VALUE" placeholders for those instead; edit the generated file directly.
  notification_gmail_user = try(local.global_vars.global.notification_gmail_user, "")

  aggregator_smtp_user = try(local.global_vars.global.aggregator_smtp_user, "")

}

terraform {
  source = "../../modules//output-file/"
}

dependency "iam" {
  config_path                            = "../iam"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    app_sa_role_arn = "arn:aws:iam::123456789012:role/dummy-app-sa"
  }
}

dependency "storage" {
  config_path                            = "../storage"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    storage_bucket_public = ""
  }
}

dependency "rds" {
  config_path                            = "../rds"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    # RDS endpoint resolves to a real, reachable host instead of a dummy.
    db_address = "common-services-postgresql.common-services.svc.cluster.local"
  }
}

dependency "random_passwords" {
  config_path                            = "../random_passwords"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    signalstack_admin_key = "dummy-signalstack-admin-key-0000000000000000"

    postgres_admin_password = "0000000000000000000000000000000c"

    signals_postgres_password   = "00000000000000000000000000000001"
    signals_redis_password      = "00000000000000000000000000000002"
    signals_auth_secret         = "00000000000000000000000000000003"
    signals_pii_key             = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    signals_notification_secret = "00000000000000000000000000000004"
    signals_dpg_scoring_secret  = "0000000000000000000000000000000000000000000000000000000000000005"
    signals_instance_shared_secret = "000000000000000000000000000000000000000000000000000000000000000d"

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
  base_location        = get_terragrunt_dir()
  cloud_storage_region = local.cloud_storage_region

  # Signals computed config inputs
  signals_public_hosts    = local.signals_public_hosts
  signals_host_bindings   = local.signals_host_bindings
  signals_network         = local.network
  signals_allowed_origins = local.signals_allowed_origins

  # IAM
  app_sa_role_arn = dependency.iam.outputs.app_sa_role_arn

  # Storage
  storage_bucket_public = dependency.storage.outputs.storage_bucket_public == null ? "" : dependency.storage.outputs.storage_bucket_public

  # RDS (managed Postgres) — endpoint hostname injected into all three chart overlays
  postgres_host = dependency.rds.outputs.db_address

  # Random secrets
  signalstack_admin_key = dependency.random_passwords.outputs.signalstack_admin_key

  postgres_admin_password = dependency.random_passwords.outputs.postgres_admin_password

  signals_postgres_password   = dependency.random_passwords.outputs.signals_postgres_password
  signals_redis_password      = dependency.random_passwords.outputs.signals_redis_password
  signals_auth_secret         = dependency.random_passwords.outputs.signals_auth_secret
  signals_pii_key             = dependency.random_passwords.outputs.signals_pii_key
  signals_notification_secret = dependency.random_passwords.outputs.signals_notification_secret
  signals_dpg_scoring_secret  = dependency.random_passwords.outputs.signals_dpg_scoring_secret
  signals_instance_shared_secret = dependency.random_passwords.outputs.signals_instance_shared_secret

  aggregator_postgres_password            = dependency.random_passwords.outputs.aggregator_postgres_password
  aggregator_kc_bootstrap_admin_password  = dependency.random_passwords.outputs.aggregator_kc_bootstrap_admin_password
  aggregator_keycloak_admin_client_secret = dependency.random_passwords.outputs.aggregator_keycloak_admin_client_secret
  aggregator_approval_token_secret        = dependency.random_passwords.outputs.aggregator_approval_token_secret
  aggregator_session_key                  = dependency.random_passwords.outputs.aggregator_session_key
  aggregator_oidc_client_secret           = dependency.random_passwords.outputs.aggregator_oidc_client_secret

  notification_gmail_user = local.notification_gmail_user

  aggregator_smtp_user = local.aggregator_smtp_user

  monitoring_grafana_password = dependency.random_passwords.outputs.monitoring_grafana_password
}
