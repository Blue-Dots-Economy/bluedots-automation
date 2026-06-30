locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region
  instance_type  = try(local.global_vars.global.pritunl_instance_type, "t3.small")
}

terraform {
  source = "../../modules//pritunl/"
}

dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id            = "vpc-dummy"
    public_subnet_ids = ["subnet-dummy-1"]
  }
}

inputs = {
  environment      = local.environment
  building_block   = local.building_block
  aws_region       = local.aws_region
  vpc_id           = dependency.network.outputs.vpc_id
  public_subnet_id = dependency.network.outputs.public_subnet_ids[0]
  instance_type    = local.instance_type
}
