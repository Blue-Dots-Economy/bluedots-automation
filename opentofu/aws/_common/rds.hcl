locals {
  global_vars    = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  environment    = local.global_vars.global.environment
  building_block = local.global_vars.global.building_block
  aws_region     = local.global_vars.global.cloud_storage_region
}

terraform {
  source = "../../modules//rds/"
}

# Private subnets for the DB subnet group + the VPC.
dependency "network" {
  config_path                            = "../network"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    vpc_id             = "vpc-dummy"
    private_subnet_ids = ["subnet-dummy-1", "subnet-dummy-2"]
  }
}

# EKS cluster security group — the only source allowed to reach Postgres on 5432.
# Managed node ENIs carry this SG, so this covers node→RDS traffic without extra plumbing.
dependency "eks" {
  config_path                            = "../eks"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    cluster_security_group_id = "sg-dummy"
  }
}

# Master password (shared with the helm `data-postgres` secret the bootstrap Job uses).
dependency "random_passwords" {
  config_path                            = "../random_passwords"
  mock_outputs_merge_strategy_with_state = "shallow"
  mock_outputs = {
    postgres_admin_password = "0000000000000000000000000000000c"
  }
}

inputs = {
  environment    = local.environment
  building_block = local.building_block
  aws_region     = local.aws_region

  vpc_id                     = dependency.network.outputs.vpc_id
  subnet_ids                 = dependency.network.outputs.private_subnet_ids
  allowed_security_group_ids = [dependency.eks.outputs.cluster_security_group_id]

  master_username = lookup(local.global_vars.global, "rds_master_username", "postgres")
  master_password = dependency.random_passwords.outputs.postgres_admin_password

  # Sizing / engine — override in global-values.yaml under global.rds_*
  engine_version        = lookup(local.global_vars.global, "rds_engine_version", "17")
  instance_class        = lookup(local.global_vars.global, "rds_instance_class", "db.t4g.micro")
  allocated_storage     = lookup(local.global_vars.global, "rds_allocated_storage", 20)
  max_allocated_storage = lookup(local.global_vars.global, "rds_max_allocated_storage", 0)
  multi_az              = lookup(local.global_vars.global, "rds_multi_az", false)
  backup_retention_days = lookup(local.global_vars.global, "rds_backup_retention_days", 7)
  deletion_protection   = lookup(local.global_vars.global, "rds_deletion_protection", true)
  skip_final_snapshot   = lookup(local.global_vars.global, "rds_skip_final_snapshot", false)
  force_ssl             = lookup(local.global_vars.global, "rds_force_ssl", false)
}
