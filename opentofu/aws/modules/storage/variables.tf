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

variable "app_bucket_key" {
  description = <<-EOT
    Logical key (in var.buckets) of the bucket the aggregator application reads and writes.
    Surfaced as the storage_bucket_app output, which iam and output-file consume.

    Exists so an environment provisioned before the private-object-storage migration can keep
    its ORIGINAL key — and therefore its original bucket name and its objects — while its
    posture is hardened in place. Changing the key changes the bucket NAME
    (<building_block>-<environment>-<account_id>-<key>), which Terraform implements as destroy
    plus create: a data migration on live participant PII, for a cosmetic rename. Those
    environments set this to "public" (a now-inaccurate suffix on a fully private bucket) and
    accept the misnomer.
  EOT
  type        = string
  default     = "private"
}

variable "buckets" {
  description = <<-EOT
    Map of logical bucket name to configuration. The S3 bucket name is auto-prefixed as
    <building_block>-<environment>-<account_id>-<key>.

    Fields:
      type               - must be "private". Public buckets are no longer provisionable;
                           every read and write goes through a pre-signed URL.
      versioning_enabled - enable S3 versioning (optional, default false)
      cors_enabled       - attach a CORS rule (optional, default TRUE). Required for any
                           bucket a browser PUTs to or GETs from with a pre-signed URL:
                           without it the preflight fails and uploads break with an error
                           that looks nothing like a permissions problem.
      lifecycle_rules    - optional per-prefix expiry. Keys are retention values in days;
                           0 or unset means "no rule for that prefix", never "expire now".
  EOT
  type = map(object({
    type               = string
    versioning_enabled = optional(bool, false)
    cors_enabled       = optional(bool, true)
    lifecycle_rules = optional(object({
      uploads_raw_retention_days    = optional(number, 0)
      uploads_errors_retention_days = optional(number, 0)
      legacy_bulk_retention_days    = optional(number, 0)
      abort_incomplete_mpu_days     = optional(number, 0)
    }), {})
  }))
  default = {
    private = {
      type               = "private"
      versioning_enabled = true
      cors_enabled       = true
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.buckets : v.type == "private"
    ])
    error_message = "Each bucket 'type' must be \"private\". Public-read buckets were removed — see docs/superpowers/plans/2026-08-22-private-object-storage-presigned-urls.md. Objects are served via pre-signed URLs."
  }

  # Map keys are inherently unique in HCL/YAML, but this validation documents the intent
  # explicitly and guards against future refactors that change the type to a list.
  validation {
    condition     = length(var.buckets) == length(distinct(keys(var.buckets)))
    error_message = "Each bucket entry must have a unique key."
  }

  # The application bucket must actually be provisioned. Without this the storage_bucket_app
  # output resolves to null, output-file renders an empty global.s3.bucket, and the failure
  # surfaces as a confusing runtime S3 error long after apply.
  validation {
    condition     = contains(keys(var.buckets), var.app_bucket_key)
    error_message = "app_bucket_key must name a key present in buckets."
  }

  # Retention must be a whole number of days and non-negative. A negative value would
  # render an invalid lifecycle rule; a fractional one is silently truncated by AWS.
  validation {
    condition = alltrue(flatten([
      for k, v in var.buckets : [
        for days in values(v.lifecycle_rules) :
        days == null || (days >= 0 && floor(days) == days)
      ]
    ]))
    error_message = "Every lifecycle_rules value must be a non-negative whole number of days (0 = no rule)."
  }
}
