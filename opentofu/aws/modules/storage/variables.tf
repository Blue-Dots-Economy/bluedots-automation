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

variable "campaign_export_expiry_days" {
  description = <<-EOT
    Days after which campaign PII export objects (under campaign_export_prefix) are deleted
    from every bucket via a lifecycle rule, so decrypted CSVs are not retained at rest longer
    than the short-lived download link. Should match the aggregator's EXPORT_URL_TTL_SECONDS
    (which is this value × 86400) — both are driven by global.campaignExportExpiryDays. 0
    disables the rule.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.campaign_export_expiry_days >= 0
    error_message = "campaign_export_expiry_days must be >= 0 (0 disables the rule)."
  }
}

variable "campaign_export_noncurrent_days" {
  description = <<-EOT
    Days after which NONCURRENT versions of campaign export objects are deleted, on buckets where
    versioning is enabled. The worker overwrites a deterministic per-job key on retry, so without
    this the superseded version keeps the same PII after the current version expires. Inert on a
    non-versioned bucket. 1 is the S3 minimum.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.campaign_export_noncurrent_days >= 1
    error_message = "campaign_export_noncurrent_days must be >= 1 (the S3 minimum)."
  }
}

variable "abort_incomplete_multipart_days" {
  description = <<-EOT
    Days after initiation that incomplete multipart uploads are aborted, BUCKET-WIDE. Orphaned parts
    from a failed upload are billed but unreachable, and aborting an incomplete upload can never
    delete a completed object — so this is safe to apply unscoped, and it needs to be: the signals
    s3-export CronJob and bulk CSV uploads both multipart outside campaign_export_prefix. 0 disables
    the rule.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.abort_incomplete_multipart_days >= 0
    error_message = "abort_incomplete_multipart_days must be >= 0 (0 disables the rule)."
  }
}

variable "campaign_export_prefix" {
  description = "Object key prefix for campaign PII exports subject to the expiry lifecycle rule. Must match the key the aggregator worker writes: campaign-exports/<signalstackOrgId>/<jobId>.csv."
  type        = string
  default     = "campaign-exports/"

  # An empty prefix would silently widen the DELETE rule to the whole bucket, taking
  # bulk-uploads/, qr/ and the signals s3-export dump with it. Fail at plan time instead.
  validation {
    condition     = length(trimspace(var.campaign_export_prefix)) > 0
    error_message = "campaign_export_prefix must not be empty — an empty prefix expires the ENTIRE bucket, not just campaign exports."
  }
}

variable "app_bucket_key" {
  description = <<-EOT
    Which entry in `buckets` is THE application bucket — the one whose name flows out as
    `storage_bucket_public` and reaches the charts as `global.s3.bucket`, and whose ARN the iam
    module writes into the app_sa S3 policy.

    This exists because the map key does double duty: it is both the bucket's NAME suffix
    (<building_block>-<environment>-<account_id>-<key>) and the lookup these outputs use. Hardcoding
    the lookup to "public" meant an operator who wanted a private-sounding name had to either accept
    a bucket called "-public" or rename the key and get a SILENTLY EMPTY `global.s3.bucket` — the
    charts have no guard on it, so the pods start healthy and the first upload fails at runtime.

    Default "public" keeps every existing environment working unchanged. Set it to the key you
    actually use ("private", say) and nothing about access changes — that is `type`, not this.
  EOT
  type        = string
  default     = "public"
}
