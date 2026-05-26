locals {
  global_vars     = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment     = local.global_vars.global.environment
  building_block  = local.global_vars.global.building_block
  aws_region      = local.global_vars.global.cloud_storage_region
}

terraform {
  source = "../../modules//storage/"
}

inputs = {
  environment          = local.environment
  building_block       = local.building_block
  aws_region           = local.aws_region
  cors_max_age_seconds = lookup(local.global_vars.global, "cors_max_age_seconds", 3000)

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
