variable "environment" {
  description = "Environment name"
  type        = string
}

variable "building_block" {
  description = "Building block name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider for EKS"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC provider URL (without https://)"
  type        = string
}

variable "storage_bucket_public" {
  description = "Public S3 bucket name"
  type        = string
}

variable "storage_bucket_private" {
  description = "Private S3 bucket name"
  type        = string
}

# Every subject listed here can assume app_sa — the aggregator api/worker and
# the signals s3-export CronJob (which shares this role and the public bucket
# instead of a dedicated exporter role). A subject missing from this list fails
# at STS assume time inside the pod, not at deploy time.
variable "service_account_subjects" {
  description = "List of Kubernetes service account subjects allowed to assume the application IAM role (format: system:serviceaccount:<namespace>:<sa-name>)"
  type        = list(string)
  default = [
    "system:serviceaccount:app:app-sa"
  ]
}

variable "permissions_boundary_policy_name" {
  description = <<-EOT
    Name of an IAM policy in THIS account to attach as the permissions boundary on every role
    this module creates. Empty (the default) attaches none, which is the right answer for any
    account that does not gate role creation on a boundary.

    Set it where the DEPLOYING principal's own IAM grants are conditioned on it — Sanketika's
    `DevOpsEngineer` permission set only allows iam:CreateRole / PutRolePolicy /
    AttachRolePolicy / PassRole when the request carries the boundary, so omitting it there
    fails with "no identity-based policy allows the iam:CreateRole action". That reads like a
    missing permission but is an unmatched condition on a grant you already have.

    A policy NAME, not an ARN: a boundary must live in the same account as the role, so the
    account id is resolved from the caller and the same value works in every account. Create
    the policy with scripts/create-permissions-boundary.sh — this repo never manages it.
  EOT
  type        = string
  default     = ""
}
