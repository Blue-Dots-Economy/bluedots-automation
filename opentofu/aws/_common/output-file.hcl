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
  notification_gmail_user = try(local.global_vars.global.notification_gmail_user, "")

  aggregator_smtp_user = try(local.global_vars.global.aggregator_smtp_user, "")

  # ── Hand-entered secrets (env's gitignored secrets.yaml) ───────────────────
  # Provider credentials no human-free source can supply: SMTP/MSG91/Maps keys,
  # Discord webhooks. Kept OUT of global-values.yaml (committed) and out of
  # random_passwords (can't be generated). Read here every apply, so a
  # regenerate of global-secrets.yaml re-renders the SAME values.
  #
  # Resolved relative to the env dir (this unit is <env>/output-file, so ".."),
  # matching how the module derives its own output paths from base_location.
  # Falls back to {} when secrets.yaml is absent — install.sh seeds it, but a
  # bare `terragrunt apply` can run first, and that shouldn't hard-fail the run.
  # The per-key try() below then supplies the placeholder for any missing key,
  # so a partially-filled file works too.
  manual_secrets_path = "${get_terragrunt_dir()}/../secrets.yaml"
  manual_secrets      = fileexists(local.manual_secrets_path) ? yamldecode(file(local.manual_secrets_path)) : {}

  smtp_password            = try(local.manual_secrets.smtp_password, "UPDATE_THIS_VALUE")
  msg91_auth_key           = try(local.manual_secrets.msg91_auth_key, "UPDATE_THIS_VALUE")
  msg91_template_id        = try(local.manual_secrets.msg91_template_id, "UPDATE_THIS_VALUE")
  google_maps_api_key      = try(local.manual_secrets.google_maps_api_key, "UPDATE_THIS_VALUE")
  google_geocoding_api_key = try(local.manual_secrets.google_geocoding_api_key, "UPDATE_THIS_VALUE")

  discord_critical_webhook = try(local.manual_secrets.discord_critical_webhook, "https://discord.com/api/webhooks/UPDATE_THIS_VALUE/UPDATE_THIS_VALUE")
  discord_warning_webhook  = try(local.manual_secrets.discord_warning_webhook, "https://discord.com/api/webhooks/UPDATE_THIS_VALUE/UPDATE_THIS_VALUE")
  discord_info_webhook     = try(local.manual_secrets.discord_info_webhook, "https://discord.com/api/webhooks/UPDATE_THIS_VALUE/UPDATE_THIS_VALUE")
}

terraform {
  source = "../../modules//output-file/"
}

dependency "iam" {
  config_path                            = "../iam"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    app_sa_role_arn         = "arn:aws:iam::123456789012:role/dummy-app-sa"
    signals_export_role_arn = ""
  }
}

dependency "storage" {
  config_path                            = "../storage"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    storage_bucket_private = ""
    buckets                = {}
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

    signals_postgres_password      = "00000000000000000000000000000001"
    signals_export_ro_password     = "0000000000000000000000000000000e"
    signals_redis_password         = "00000000000000000000000000000002"
    signals_auth_secret            = "00000000000000000000000000000003"
    signals_pii_key                = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    signals_notification_secret    = "00000000000000000000000000000004"
    signals_search_api_key         = "dummy-signals-search-api-key-00000000000000"
    signals_instance_shared_secret = "000000000000000000000000000000000000000000000000000000000000000d"

    aggregator_postgres_password            = "0000000000000000000000000000000000000000000000000000000000000006"
    keycloak_postgres_password              = "000000000000000000000000000000000000000000000000000000000000000f"
    signals_api_client_secret               = "0000000000000000000000000000000000000000000000000000000000000010"
    signalstack_client_secret               = "0000000000000000000000000000000000000000000000000000000000000011"
    voice_dpg_signals_secret                = "0000000000000000000000000000000000000000000000000000000000000012"
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
  app_sa_role_arn         = dependency.iam.outputs.app_sa_role_arn
  signals_export_role_arn = dependency.iam.outputs.signals_export_role_arn == null ? "" : dependency.iam.outputs.signals_export_role_arn

  # Storage
  storage_bucket_private = dependency.storage.outputs.storage_bucket_private == null ? "" : dependency.storage.outputs.storage_bucket_private
  signed_url_ttl_seconds = lookup(local.global_vars.global, "signed_url_ttl_seconds", 600)
  signals_export_bucket = try(dependency.storage.outputs.buckets["signals-export"].id, "")

  # RDS (managed Postgres) — endpoint hostname injected into all three chart overlays
  postgres_host = dependency.rds.outputs.db_address

  # Random secrets
  signalstack_admin_key = dependency.random_passwords.outputs.signalstack_admin_key

  postgres_admin_password = dependency.random_passwords.outputs.postgres_admin_password

  signals_postgres_password      = dependency.random_passwords.outputs.signals_postgres_password
  signals_export_ro_password     = dependency.random_passwords.outputs.signals_export_ro_password
  signals_redis_password         = dependency.random_passwords.outputs.signals_redis_password
  signals_auth_secret            = dependency.random_passwords.outputs.signals_auth_secret
  signals_pii_key                = dependency.random_passwords.outputs.signals_pii_key
  signals_notification_secret    = dependency.random_passwords.outputs.signals_notification_secret
  signals_search_api_key         = dependency.random_passwords.outputs.signals_search_api_key
  signals_instance_shared_secret = dependency.random_passwords.outputs.signals_instance_shared_secret

  aggregator_postgres_password            = dependency.random_passwords.outputs.aggregator_postgres_password
  keycloak_postgres_password              = dependency.random_passwords.outputs.keycloak_postgres_password
  signals_api_client_secret               = dependency.random_passwords.outputs.signals_api_client_secret
  signalstack_client_secret               = dependency.random_passwords.outputs.signalstack_client_secret
  voice_dpg_signals_secret                = dependency.random_passwords.outputs.voice_dpg_signals_secret
  aggregator_kc_bootstrap_admin_password  = dependency.random_passwords.outputs.aggregator_kc_bootstrap_admin_password
  aggregator_keycloak_admin_client_secret = dependency.random_passwords.outputs.aggregator_keycloak_admin_client_secret
  aggregator_approval_token_secret        = dependency.random_passwords.outputs.aggregator_approval_token_secret
  aggregator_session_key                  = dependency.random_passwords.outputs.aggregator_session_key
  aggregator_oidc_client_secret           = dependency.random_passwords.outputs.aggregator_oidc_client_secret

  notification_gmail_user = local.notification_gmail_user

  aggregator_smtp_user = local.aggregator_smtp_user

  # Hand-entered secrets from the env's secrets.yaml
  smtp_password            = local.smtp_password
  msg91_auth_key           = local.msg91_auth_key
  msg91_template_id        = local.msg91_template_id
  google_maps_api_key      = local.google_maps_api_key
  google_geocoding_api_key = local.google_geocoding_api_key
  discord_critical_webhook = local.discord_critical_webhook
  discord_warning_webhook  = local.discord_warning_webhook
  discord_info_webhook     = local.discord_info_webhook

  monitoring_grafana_password = dependency.random_passwords.outputs.monitoring_grafana_password
}
