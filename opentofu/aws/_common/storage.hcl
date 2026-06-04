locals {
  global_vars     = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment     = local.global_vars.global.environment
  building_block  = local.global_vars.global.building_block
  aws_region      = local.global_vars.global.cloud_storage_region

  # Domain buckets should be reachable from. Drives both the CORS allow-list and the
  # public-read aws:Referer scope so buckets are NOT open to "*".
  aggregator_host = lookup(local.global_vars.global, "aggregator_host", "")

  # https origin for CORS; referer pattern (host + path glob) for the bucket policy.
  cors_allowed_origins = local.aggregator_host != "" ? ["https://${local.aggregator_host}"] : []
  allowed_referers     = local.aggregator_host != "" ? ["https://${local.aggregator_host}/*"] : []
}

terraform {
  source = "../../modules//storage/"
}

inputs = {
  environment          = local.environment
  building_block       = local.building_block
  aws_region           = local.aws_region
  cors_max_age_seconds = lookup(local.global_vars.global, "cors_max_age_seconds", 3000)

  # Restrict cross-origin + public-read access to the aggregator domain only (never "*").
  cors_allowed_origins = local.cors_allowed_origins
  allowed_referers     = local.allowed_referers

  # Bucket definitions — override in global-values.yaml under global.buckets
  # Each entry: { type = "public"|"private", versioning_enabled = bool, cors_enabled = bool }
  buckets = lookup(local.global_vars.global, "buckets", {
    public = {
      type         = "public"
      cors_enabled = true
    }
    private = {
      type               = "private"
      versioning_enabled = true
    }
  })
}
