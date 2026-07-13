locals {
  global_vars                                   = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  postgres_admin_password_bytes                 = try(local.global_vars.global.postgres_admin_password_bytes, 16)
  signals_postgres_password_bytes               = try(local.global_vars.global.signals_postgres_password_bytes, 16)
  signals_redis_password_bytes                  = try(local.global_vars.global.signals_redis_password_bytes, 16)
  signals_auth_secret_bytes                     = try(local.global_vars.global.signals_auth_secret_bytes, 32)
  signals_notification_secret_bytes             = try(local.global_vars.global.signals_notification_secret_bytes, 32)
  signals_dpg_scoring_secret_bytes              = try(local.global_vars.global.signals_dpg_scoring_secret_bytes, 32)
  signals_instance_shared_secret_bytes          = try(local.global_vars.global.signals_instance_shared_secret_bytes, 32)
  aggregator_postgres_password_bytes            = try(local.global_vars.global.aggregator_postgres_password_bytes, 16)
  aggregator_kc_bootstrap_admin_password_bytes  = try(local.global_vars.global.aggregator_kc_bootstrap_admin_password_bytes, 16)
  aggregator_keycloak_admin_client_secret_bytes = try(local.global_vars.global.aggregator_keycloak_admin_client_secret_bytes, 32)
  aggregator_approval_token_secret_bytes        = try(local.global_vars.global.aggregator_approval_token_secret_bytes, 32)
  aggregator_session_key_bytes                  = try(local.global_vars.global.aggregator_session_key_bytes, 32)
  aggregator_oidc_client_secret_bytes           = try(local.global_vars.global.aggregator_oidc_client_secret_bytes, 32)
  encryption_string_length                      = try(local.global_vars.global.encryption_string_length, 32)
  random_string_length                          = try(local.global_vars.global.random_string_length, 24)
  signalstack_admin_key_length                  = try(local.global_vars.global.signalstack_admin_key_length, 48)
  monitoring_grafana_password_length            = try(local.global_vars.global.monitoring_grafana_password_length, 16)
}

terraform {
  source = "../../modules//random_passwords/"
}

inputs = {
  postgres_admin_password_bytes                 = local.postgres_admin_password_bytes
  signals_postgres_password_bytes               = local.signals_postgres_password_bytes
  signals_redis_password_bytes                  = local.signals_redis_password_bytes
  signals_auth_secret_bytes                     = local.signals_auth_secret_bytes
  signals_notification_secret_bytes             = local.signals_notification_secret_bytes
  signals_dpg_scoring_secret_bytes              = local.signals_dpg_scoring_secret_bytes
  signals_instance_shared_secret_bytes          = local.signals_instance_shared_secret_bytes
  aggregator_postgres_password_bytes            = local.aggregator_postgres_password_bytes
  aggregator_kc_bootstrap_admin_password_bytes  = local.aggregator_kc_bootstrap_admin_password_bytes
  aggregator_keycloak_admin_client_secret_bytes = local.aggregator_keycloak_admin_client_secret_bytes
  aggregator_approval_token_secret_bytes        = local.aggregator_approval_token_secret_bytes
  aggregator_session_key_bytes                  = local.aggregator_session_key_bytes
  aggregator_oidc_client_secret_bytes           = local.aggregator_oidc_client_secret_bytes
  encryption_string_length                      = local.encryption_string_length
  random_string_length                          = local.random_string_length
  signalstack_admin_key_length                  = local.signalstack_admin_key_length
  monitoring_grafana_password_length            = local.monitoring_grafana_password_length
}
