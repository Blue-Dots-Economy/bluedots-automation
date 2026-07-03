locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region
  create_network = lookup(local.global_vars.global, "create_network", true)
}

terraform {
  source = "../../modules//network/"
}

inputs = {
  environment    = local.environment
  building_block = local.building_block
  aws_region     = local.aws_region
  create_network = local.create_network

  # Optional: bring-your-own VPC (used when create_network = false)
  vpc_id             = lookup(local.global_vars.global, "vpc_id", "")
  private_subnet_ids = lookup(local.global_vars.global, "private_subnet_ids", [])
  public_subnet_ids  = lookup(local.global_vars.global, "public_subnet_ids", [])

  # VPC CIDR (optional override)
  vpc_cidr = lookup(local.global_vars.global, "vpc_cidr", "10.0.0.0/16")

  # Subnet definitions — override in global-values.yaml under global.subnet_config
  subnet_config = lookup(local.global_vars.global, "subnet_config", {
    public-a = { type = "public", availability_zone = "a", cidr_netnum = 0 }
    public-b = { type = "public", availability_zone = "b", cidr_netnum = 1 }
  })

  # NAT Gateway (optional override — default false; set true only if private subnets need internet egress)
  nat_gateway_enabled = lookup(local.global_vars.global, "nat_gateway_enabled", false)

  # Security group ingress (optional override)
  ingress_cidr_blocks = lookup(local.global_vars.global, "ingress_cidr_blocks", ["0.0.0.0/0"])
}
