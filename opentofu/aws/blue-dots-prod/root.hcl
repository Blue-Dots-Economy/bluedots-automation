locals {
  global_vars = yamldecode(file("${get_terragrunt_dir()}/../global-values.yaml"))
  aws_region  = local.global_vars.global.cloud_storage_region
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
terraform {
  backend "s3" {
    # Environment variables required (exported by create_tf_backend.sh):
    # - TERRAFORM_BACKEND_BUCKET: S3 bucket name
    # - AWS_REGION: AWS region
    bucket  = "${get_env("TERRAFORM_BACKEND_BUCKET", "")}"
    key     = "${path_relative_to_include()}/terraform.tfstate"
    region  = "${get_env("AWS_REGION", "us-east-1")}"
    encrypt = true
  }
}
EOF
}
