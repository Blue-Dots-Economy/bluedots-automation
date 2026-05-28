variable "output_file_path" {
  description = "Absolute path of the generated global-cloud-values.yaml file"
  type        = string
}

variable "building_block" {
  description = "Naming prefix used for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
variable "network" {
  description = "Aggregated outputs of the network module"
  type = object({
    vpc_id                 = string
    vpc_cidr_block         = string
    public_subnet_ids      = list(string)
    private_subnet_ids     = list(string)
    internet_gateway_id    = optional(string)
    nat_gateway_id         = optional(string)
    nat_gateway_public_ip  = optional(string)
    public_route_table_id  = optional(string)
    private_route_table_id = optional(string)
    security_group_id      = optional(string)
    subnets                = any
  })
}

# -----------------------------------------------------------------------------
# EKS
# -----------------------------------------------------------------------------
variable "eks" {
  description = "Aggregated outputs of the eks module"
  type = object({
    cluster_id                        = string
    cluster_name                      = string
    cluster_arn                       = string
    cluster_endpoint                  = string
    cluster_security_group_id         = string
    oidc_provider_arn                 = string
    oidc_provider                     = string
    node_role_arn                     = string
    private_lb_ip                     = optional(string)
    cloudwatch_observability_role_arn = optional(string)
  })
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------
variable "iam" {
  description = "Aggregated outputs of the iam module"
  type = object({
    app_sa_role_arn  = string
    app_sa_role_name = string
  })
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------
variable "storage" {
  description = "Aggregated outputs of the storage module"
  type = object({
    buckets                      = any
    storage_bucket_public        = optional(string)
    storage_bucket_public_arn    = optional(string)
    storage_bucket_public_domain = optional(string)
    storage_bucket_private       = optional(string)
    storage_bucket_private_arn   = optional(string)
    dial_bucket                  = optional(string)
    dial_bucket_arn              = optional(string)
    velero_bucket                = optional(string)
    velero_bucket_arn            = optional(string)
  })
}
