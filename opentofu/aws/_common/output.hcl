locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region

  # global-cloud-values.yaml lives next to global-values.yaml in the template dir
  # (one level up from this stack's terragrunt config directory).
  output_file_path = abspath("${get_terragrunt_dir()}/../global-cloud-values.yaml")
}

terraform {
  source = "../../modules//output/"
}

dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id                 = "vpc-dummy"
    vpc_cidr_block         = "10.0.0.0/16"
    public_subnet_ids      = ["subnet-dummy-1", "subnet-dummy-2"]
    private_subnet_ids     = []
    internet_gateway_id    = "igw-dummy"
    nat_gateway_id         = null
    nat_gateway_public_ip  = null
    public_route_table_id  = "rtb-dummy-pub"
    private_route_table_id = null
    security_group_id      = "sg-dummy"
    subnets                = {}
  }
}

dependency "eks" {
  config_path                            = "../eks"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cluster_id                        = "dummy-cluster"
    cluster_name                      = "dummy-cluster"
    cluster_arn                       = "arn:aws:eks:us-east-1:123456789012:cluster/dummy"
    cluster_endpoint                  = "https://dummy.eks.amazonaws.com"
    cluster_security_group_id         = "sg-dummy-eks"
    oidc_provider_arn                 = "arn:aws:iam::123456789012:oidc-provider/dummy"
    oidc_provider                     = "oidc.eks.us-east-1.amazonaws.com/id/DUMMY"
    node_role_arn                     = "arn:aws:iam::123456789012:role/dummy-node"
    private_lb_ip                     = null
    cloudwatch_observability_role_arn = null
  }
}

dependency "iam" {
  config_path                            = "../iam"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    app_sa_role_arn  = "arn:aws:iam::123456789012:role/dummy-app-sa"
    app_sa_role_name = "dummy-app-sa"
  }
}

dependency "storage" {
  config_path                            = "../storage"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    buckets                      = {}
    storage_bucket_public        = null
    storage_bucket_public_arn    = null
    storage_bucket_public_domain = null
    storage_bucket_private       = null
    storage_bucket_private_arn   = null
    dial_bucket                  = null
    dial_bucket_arn              = null
    velero_bucket                = null
    velero_bucket_arn            = null
  }
}

inputs = {
  output_file_path = local.output_file_path
  building_block   = local.building_block
  environment      = local.environment
  aws_region       = local.aws_region

  network = {
    vpc_id                 = dependency.network.outputs.vpc_id
    vpc_cidr_block         = dependency.network.outputs.vpc_cidr_block
    public_subnet_ids      = dependency.network.outputs.public_subnet_ids
    private_subnet_ids     = dependency.network.outputs.private_subnet_ids
    internet_gateway_id    = dependency.network.outputs.internet_gateway_id
    nat_gateway_id         = dependency.network.outputs.nat_gateway_id
    nat_gateway_public_ip  = dependency.network.outputs.nat_gateway_public_ip
    public_route_table_id  = dependency.network.outputs.public_route_table_id
    private_route_table_id = dependency.network.outputs.private_route_table_id
    security_group_id      = dependency.network.outputs.security_group_id
    subnets                = dependency.network.outputs.subnets
  }

  eks = {
    cluster_id                        = dependency.eks.outputs.cluster_id
    cluster_name                      = dependency.eks.outputs.cluster_name
    cluster_arn                       = dependency.eks.outputs.cluster_arn
    cluster_endpoint                  = dependency.eks.outputs.cluster_endpoint
    cluster_security_group_id         = dependency.eks.outputs.cluster_security_group_id
    oidc_provider_arn                 = dependency.eks.outputs.oidc_provider_arn
    oidc_provider                     = dependency.eks.outputs.oidc_provider
    node_role_arn                     = dependency.eks.outputs.node_role_arn
    private_lb_ip                     = dependency.eks.outputs.private_lb_ip
    cloudwatch_observability_role_arn = dependency.eks.outputs.cloudwatch_observability_role_arn
  }

  iam = {
    app_sa_role_arn  = dependency.iam.outputs.app_sa_role_arn
    app_sa_role_name = dependency.iam.outputs.app_sa_role_name
  }

  storage = {
    buckets                      = dependency.storage.outputs.buckets
    storage_bucket_public        = dependency.storage.outputs.storage_bucket_public
    storage_bucket_public_arn    = dependency.storage.outputs.storage_bucket_public_arn
    storage_bucket_public_domain = dependency.storage.outputs.storage_bucket_public_domain
    storage_bucket_private       = dependency.storage.outputs.storage_bucket_private
    storage_bucket_private_arn   = dependency.storage.outputs.storage_bucket_private_arn
    dial_bucket                  = dependency.storage.outputs.dial_bucket
    dial_bucket_arn              = dependency.storage.outputs.dial_bucket_arn
    velero_bucket                = dependency.storage.outputs.velero_bucket
    velero_bucket_arn            = dependency.storage.outputs.velero_bucket_arn
  }
}
