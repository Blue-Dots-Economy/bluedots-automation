locals {
  global_vars     = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment     = local.global_vars.global.environment
  building_block  = local.global_vars.global.building_block
  aws_region      = local.global_vars.global.cloud_storage_region
}

terraform {
  source = "../../modules//iam/"
}

dependency "eks" {
  config_path = "../eks"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
    oidc_provider     = "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
  }
}

dependency "storage" {
  config_path = "../storage"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    buckets = {
      public  = { id = "dummy-public-bucket",  arn = "arn:aws:s3:::dummy-public-bucket",  domain = "dummy-public-bucket.s3.amazonaws.com",  type = "public" }
      private = { id = "dummy-private-bucket", arn = "arn:aws:s3:::dummy-private-bucket", domain = "dummy-private-bucket.s3.amazonaws.com", type = "private" }
    }
    storage_bucket_public  = "dummy-public-bucket"
    storage_bucket_private = "dummy-private-bucket"
    dial_bucket            = null
    velero_bucket          = null
  }
}

inputs = {
  environment                = local.environment
  building_block             = local.building_block
  aws_region                 = local.aws_region
  oidc_provider_arn          = dependency.eks.outputs.oidc_provider_arn
  oidc_provider              = dependency.eks.outputs.oidc_provider
  storage_bucket_public      = dependency.storage.outputs.storage_bucket_public
  storage_bucket_private     = dependency.storage.outputs.storage_bucket_private
  service_account_subjects   = lookup(local.global_vars.global, "service_account_subjects", [
    "system:serviceaccount:app:app-sa"
  ])
}
