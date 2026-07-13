locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region
  # Optional AWS key pair; null when access is granted via authorized_keys (the default path).
  key_name        = try(local.global_vars.global.bastion_key_name, null)
  authorized_keys = try(local.global_vars.global.bastion_authorized_keys, [])
  instance_type   = try(local.global_vars.global.bastion_instance_type, "t3.medium")
}

terraform {
  source = "../../modules//bastion/"
}

dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id                 = "vpc-dummy"
    vpc_cidr_block         = "10.0.0.0/16"
    private_eks_subnet_ids = ["subnet-dummy-1"]
  }
}

# Bastion needs the cluster name to create its EKS access entry. This makes the
# apply order: network → eks → bastion.
dependency "eks" {
  config_path                            = "../eks"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cluster_name = "cluster-dummy"
  }
}

inputs = {
  environment    = local.environment
  building_block = local.building_block
  aws_region     = local.aws_region
  vpc_id         = dependency.network.outputs.vpc_id
  vpc_cidr       = dependency.network.outputs.vpc_cidr_block
  subnet_id      = dependency.network.outputs.private_eks_subnet_ids[0]
  cluster_name    = dependency.eks.outputs.cluster_name
  instance_type   = local.instance_type
  key_name        = local.key_name
  authorized_keys = local.authorized_keys
}
