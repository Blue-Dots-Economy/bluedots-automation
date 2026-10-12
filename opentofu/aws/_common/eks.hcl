locals {
  global_vars         = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment         = local.global_vars.global.environment
  building_block      = local.global_vars.global.building_block
  aws_region          = local.global_vars.global.cloud_storage_region
  eks_cluster_version = local.global_vars.global.eks_cluster_version
  node_instance_type  = local.global_vars.global.eks_node_instance_type
  node_disk_size_gb   = local.global_vars.global.eks_node_disk_size_gb
  node_count_min      = local.global_vars.global.eks_node_count_min
  node_count_max      = local.global_vars.global.eks_node_count_max

  enable_cloudwatch_observability  = try(local.global_vars.global.enable_cloudwatch_observability, false)
  cloudwatch_enabled_log_types     = try(local.global_vars.global.cloudwatch_enabled_log_types, ["api", "controllerManager", "scheduler"])
  cloudwatch_log_retention_in_days = try(local.global_vars.global.cloudwatch_log_retention_in_days, 30)
  endpoint_public_access          = try(local.global_vars.global.eks_endpoint_public_access, true)
  endpoint_private_access         = try(local.global_vars.global.eks_endpoint_private_access, false)
  node_count_desired              = try(local.global_vars.global.eks_node_count_desired, null)
  node_capacity_type              = try(local.global_vars.global.eks_node_capacity_type, "ON_DEMAND")
  ebs_csi_addon_version           = try(local.global_vars.global.eks_ebs_csi_addon_version, null)

  # Optional: restrict the managed node group to specific subnet logical names
  # (e.g. ["private-eks-a"]) to pin all nodes into one AZ. Use this for a single-node
  # cluster so the node always lands in the AZ where the EBS volumes live (EBS is
  # AZ-locked). Leave empty to spread nodes across all private-eks-* subnets (multi-AZ).
  node_subnet_keys = try(local.global_vars.global.eks_node_subnet_keys, [])
}

terraform {
  source = "../../modules//eks/"
}

dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id                 = "vpc-dummy"
    public_subnet_ids      = ["subnet-dummy-3", "subnet-dummy-4"]
    private_eks_subnet_ids = []
    security_group_id      = "sg-dummy"
    # Non-empty so a brand-new environment's first-ever `run --all apply` doesn't crash before
    # network even runs: eks_node_subnet_keys indexes this map (line below), and on a fresh
    # environment `network` has no real state yet, so Terragrunt falls back to this mock to even
    # generate eks's plan. An empty map there makes ANY non-empty eks_node_subnet_keys fail with
    # "Invalid index" at plan-graph time — real values replace these the moment network applies.
    subnets = {
      for k in ["public-a", "public-b", "private-a", "private-b", "private-eks-a", "private-eks-b"] : k => {
        id                = "subnet-dummy-${k}"
        arn               = "arn:aws:ec2:ap-south-1:000000000000:subnet/subnet-dummy-${k}"
        cidr_block        = "10.0.0.0/24"
        availability_zone = "ap-south-1a"
        type              = "private"
      }
    }
  }
}

inputs = {
  environment       = local.environment
  building_block    = local.building_block
  aws_region        = local.aws_region
  vpc_id            = dependency.network.outputs.vpc_id
  public_subnet_ids = dependency.network.outputs.public_subnet_ids
  # When eks_node_subnet_keys is set, pin the node group to exactly those subnets (one AZ
  # for single-node). Otherwise use all private-eks-* subnets, or null (= public subnets) if none exist.
  node_subnet_ids = (
    length(local.node_subnet_keys) > 0
    ? [for k in local.node_subnet_keys : dependency.network.outputs.subnets[k].id]
    : (length(dependency.network.outputs.private_eks_subnet_ids) > 0 ? dependency.network.outputs.private_eks_subnet_ids : null)
  )
  cluster_version    = local.eks_cluster_version
  node_instance_type = local.node_instance_type
  node_disk_size_gb  = local.node_disk_size_gb
  node_count_min     = local.node_count_min
  node_count_max     = local.node_count_max

  enable_cloudwatch_observability  = local.enable_cloudwatch_observability
  cloudwatch_enabled_log_types     = local.cloudwatch_enabled_log_types
  cloudwatch_log_retention_in_days = local.cloudwatch_log_retention_in_days
  security_group_ids              = [dependency.network.outputs.security_group_id]
  endpoint_public_access          = local.endpoint_public_access
  endpoint_private_access         = local.endpoint_private_access
  node_count_desired              = local.node_count_desired
  node_capacity_type              = local.node_capacity_type
  ebs_csi_addon_version           = local.ebs_csi_addon_version
  # Name of an IAM policy in this account attached as the permissions boundary on every role
  # this module creates. Optional: absent/empty attaches none. See modules/<m>/variables.tf.
  # try(..., null) not lookup(..., ""): null means the key is ABSENT (a
  # global-values.yaml written before the boundary existed), "" means an
  # operator deliberately chose no boundary. Both attach nothing, but only the
  # first is a mistake — the module warns on it via a check block.
  permissions_boundary_policy_name = try(local.global_vars.global.permissions_boundary_policy_name, null)
}
