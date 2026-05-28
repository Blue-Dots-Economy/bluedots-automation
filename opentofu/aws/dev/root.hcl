locals {
  global_vars = yamldecode(file("${get_terragrunt_dir()}/../global-values.yaml"))
  aws_region  = local.global_vars.global.cloud_storage_region
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  backend "local" {
    path = "${get_parent_terragrunt_dir()}/.terraform/${path_relative_to_include()}/terraform.tfstate"
  }
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
}
EOF
}
