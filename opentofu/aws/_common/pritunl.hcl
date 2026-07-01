locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region
  instance_type  = try(local.global_vars.global.pritunl_instance_type, "t3.small")
  # Shares the deployment's admin key pair (the one created for the bastion) so you can
  # SSH in for the one-time Pritunl setup. null = no SSH access to the Pritunl host.
  key_name = try(local.global_vars.global.bastion_key_name, null)
  # Same public-key list as the bastion — lets the same developers SSH in for setup.
  authorized_keys = try(local.global_vars.global.bastion_authorized_keys, [])
  # CIDRs allowed to reach the VPN. Default open; set to office/home CIDRs to restrict.
  ingress_cidrs = try(local.global_vars.global.pritunl_ingress_cidrs, ["0.0.0.0/0"])
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
  key_name         = local.key_name
  authorized_keys  = local.authorized_keys
  ingress_cidrs    = local.ingress_cidrs
}
