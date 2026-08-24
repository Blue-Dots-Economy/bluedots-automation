locals {
  global_vars     = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment     = local.global_vars.global.environment
  building_block  = local.global_vars.global.building_block
  aws_region      = local.global_vars.global.cloud_storage_region

  # Domain the browser talks to the bucket from. SOLE source of the CORS allow-list
  # now that the public-read aws:Referer scope is gone. Must be set: without it the
  # bucket gets no CORS rule and every pre-signed upload fails at preflight (the
  # storage module raises a precondition rather than shipping that silently).
  aggregator_host = lookup(local.global_vars.global, "aggregator_host", "")

  cors_allowed_origins = local.aggregator_host != "" ? ["https://${local.aggregator_host}"] : []
}

terraform {
  source = "../../modules//storage/"
}

inputs = {
  environment          = local.environment
  building_block       = local.building_block
  aws_region           = local.aws_region
  cors_max_age_seconds = lookup(local.global_vars.global, "cors_max_age_seconds", 3000)

  # Restrict cross-origin access to the aggregator domain only (never "*").
  cors_allowed_origins = local.cors_allowed_origins

  # Bucket definitions — override in global-values.yaml under global.buckets.
  # Each entry: { type = "private", versioning_enabled = bool, cors_enabled = bool,
  #               lifecycle_rules = { ...retention days... } }
  buckets = lookup(local.global_vars.global, "buckets", {
    private = {
      type               = "private"
      versioning_enabled = true
      cors_enabled       = true
    }
  })
}
