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
  # Two lists, because 1194 and 22/443 are different risks — see modules/pritunl/variables.tf.
  # 1194 is open by default: Pritunl authenticates each connection with a per-user certificate,
  # so a source-IP gate there only locks out home/mobile users whose ISP lease moved.
  vpn_ingress_cidrs = try(local.global_vars.global.pritunl_vpn_ingress_cidrs, ["0.0.0.0/0"])
  # SSH + the web admin UI. Falls back to the legacy single-list key so an <env>/global-values.yaml
  # written before the split keeps its curated office CIDRs on the admin ports (and only there) with
  # no edit. The VPC CIDR is added inside the module, so [] still leaves both reachable over the VPN.
  admin_ingress_cidrs = try(
    local.global_vars.global.pritunl_admin_ingress_cidrs,
    try(local.global_vars.global.pritunl_ingress_cidrs, []),
  )
}

terraform {
  source = "../../modules//pritunl/"
}

dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id            = "vpc-dummy"
    vpc_cidr_block    = "10.0.0.0/16"
    public_subnet_ids = ["subnet-dummy-1"]
  }
}

inputs = {
  environment      = local.environment
  building_block   = local.building_block
  aws_region       = local.aws_region
  vpc_id           = dependency.network.outputs.vpc_id
  vpc_cidr         = dependency.network.outputs.vpc_cidr_block
  public_subnet_id = dependency.network.outputs.public_subnet_ids[0]
  instance_type    = local.instance_type
  key_name         = local.key_name
  authorized_keys  = local.authorized_keys

  vpn_ingress_cidrs   = local.vpn_ingress_cidrs
  admin_ingress_cidrs = local.admin_ingress_cidrs
  # Name of an IAM policy in this account attached as the permissions boundary on every role
  # this module creates. Optional: absent/empty attaches none. See modules/<m>/variables.tf.
  # try(..., null) not lookup(..., ""): null means the key is ABSENT (a
  # global-values.yaml written before the boundary existed), "" means an
  # operator deliberately chose no boundary. Both attach nothing, but only the
  # first is a mistake — the module warns on it via a check block.
  permissions_boundary_policy_name = try(local.global_vars.global.permissions_boundary_policy_name, null)
}
