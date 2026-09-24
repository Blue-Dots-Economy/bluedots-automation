locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region
}

terraform {
  source = "../../modules//backup/"
}

# The only dependency: the cluster ARN this plan protects.
dependency "eks" {
  config_path                            = "../eks"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cluster_arn = "arn:aws:eks:ap-south-1:000000000000:cluster/dummy"
  }
}

inputs = {
  environment    = local.environment
  building_block = local.building_block
  aws_region     = local.aws_region

  eks_cluster_arn = dependency.eks.outputs.cluster_arn

  permissions_boundary_policy_name = lookup(local.global_vars.global, "permissions_boundary_policy_name", null)

  # backup_schedule / backup_retention_days have NO real default here — try() only keeps
  # `terragrunt run --all` from erroring on environments where backup_enabled is still false and
  # these keys don't exist in global-values.yaml yet. Once backup_enabled is true, the module's
  # own precondition rejects "" / 0 with a clear message.
  backup_schedule           = try(local.global_vars.global.backup_schedule, "")
  backup_retention_days     = try(local.global_vars.global.backup_retention_days, 0)
  backup_min_retention_days = lookup(local.global_vars.global, "backup_min_retention_days", 7)
  backup_max_retention_days = lookup(local.global_vars.global, "backup_max_retention_days", 35)
  backup_start_window       = lookup(local.global_vars.global, "backup_start_window", 60)
  backup_completion_window  = lookup(local.global_vars.global, "backup_completion_window", 300)
  backup_alert_emails       = lookup(local.global_vars.global, "backup_alert_emails", [])
  backup_enable_s3          = lookup(local.global_vars.global, "backup_enable_s3", false)
}
