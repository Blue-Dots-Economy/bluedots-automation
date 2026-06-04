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

variable "cors_allowed_origins" {
  description = <<-EOT
    Explicit list of origins allowed for cross-origin (CORS) requests on cors_enabled buckets,
    e.g. ["https://aggregator.example.com"]. Wildcard "*" is rejected — origins must be specific.
    Typically derived from global.aggregator_host in global-values.yaml.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.cors_allowed_origins, "*")
    error_message = "cors_allowed_origins must not contain \"*\". List explicit origins (e.g. https://aggregator.example.com)."
  }
}

variable "cors_allowed_methods" {
  description = "HTTP methods permitted by the CORS rule on cors_enabled buckets."
  type        = list(string)
  default     = ["GET", "HEAD", "PUT"]
}

variable "cors_allowed_headers" {
  description = "Request headers permitted by the CORS rule on cors_enabled buckets."
  type        = list(string)
  default     = ["Authorization", "Content-Type", "Content-MD5", "x-amz-acl", "x-amz-date", "x-amz-content-sha256"]
}

variable "allowed_referers" {
  description = <<-EOT
    Referer patterns (aws:Referer) that may read objects from public buckets, e.g.
    ["https://aggregator.example.com/*"]. When non-empty, the public-read policy is scoped to
    these referers instead of being open to the whole internet. Typically derived from
    global.aggregator_host. NOTE: aws:Referer is a defense-in-depth control (clients can spoof
    the header); pair it with CORS and, for stronger isolation, front the bucket with CloudFront + OAC.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.allowed_referers, "*")
    error_message = "allowed_referers must not contain \"*\". List explicit referer patterns."
  }
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
