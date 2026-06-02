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

variable "cors_max_age_seconds" {
  description = "Max age (seconds) for CORS preflight response cache on buckets with cors_enabled = true"
  type        = number
  default     = 3000
}

variable "buckets" {
  description = <<-EOT
    Map of logical bucket name to configuration. The S3 bucket name is auto-prefixed as
    <building_block>-<environment>-<account_id>-<key>.

    Fields:
      type               - "public" or "private" (required)
      versioning_enabled - enable S3 versioning (optional, default false)
      cors_enabled       - attach a CORS rule using cors_max_age_seconds (optional, default false)
  EOT
  type = map(object({
    type               = string
    versioning_enabled = optional(bool, false)
    cors_enabled       = optional(bool, false)
  }))
  default = {
    public = {
      type         = "public"
      cors_enabled = true
    }
    private = {
      type               = "private"
      versioning_enabled = true
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets : contains(["public", "private"], v.type)
    ])
    error_message = "Each bucket 'type' must be either \"public\" or \"private\"."
  }

  # Map keys are inherently unique in HCL/YAML, but this validation documents the intent
  # explicitly and guards against future refactors that change the type to a list.
  validation {
    condition     = length(var.buckets) == length(distinct(keys(var.buckets)))
    error_message = "Each bucket entry must have a unique key."
  }
}
