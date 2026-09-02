# ---------------------------------------------------------------------------------------------------------------------
# Generic output — all buckets keyed by logical name (the key used in var.buckets)
# Consumers can iterate over this to build ARN lists, domain lists, etc.
# ---------------------------------------------------------------------------------------------------------------------

output "buckets" {
  description = "All provisioned buckets keyed by logical name (same key as var.buckets)"
  value = {
    for k, b in aws_s3_bucket.this : k => {
      id     = b.id
      arn    = b.arn
      domain = b.bucket_regional_domain_name
      type   = var.buckets[k].type
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Convenience outputs for the two conventional buckets (key = "public" / "private").
# Return null if those keys are not present in var.buckets so callers can use try().
# These preserve backward compatibility with storage-user, iam, and output-file modules.
# ---------------------------------------------------------------------------------------------------------------------

# The APPLICATION bucket — keyed by var.app_bucket_key, not by the literal "public".
# The output NAMES keep the `_public` suffix so iam/output-file and every existing environment
# consume them unchanged; only which entry they resolve is now configurable.
#
# A precondition rather than try(..., null): a missing key used to yield null, which
# _common/output-file.hcl turns into "", which renders an EMPTY global.s3.bucket. No chart guards
# that value, so the aggregator installs green and fails on the first upload/QR/CSV — hours later
# and nowhere near the cause. Fail at plan time instead.

output "storage_bucket_public" {
  description = "Name of the application bucket (the `var.app_bucket_key` entry in `buckets`)"
  value       = aws_s3_bucket.this[var.app_bucket_key].id

  precondition {
    condition     = contains(keys(var.buckets), var.app_bucket_key)
    error_message = "app_bucket_key = \"${var.app_bucket_key}\" is not a key in `buckets` (have: ${join(", ", keys(var.buckets))}). It selects the application bucket; a wrong value renders an empty global.s3.bucket and breaks uploads at runtime, not at deploy."
  }
}

output "storage_bucket_public_arn" {
  description = "ARN of the application bucket (the `var.app_bucket_key` entry in `buckets`)"
  value       = aws_s3_bucket.this[var.app_bucket_key].arn
}

output "storage_bucket_public_domain" {
  description = "Regional domain of the application bucket (the `var.app_bucket_key` entry)"
  value       = aws_s3_bucket.this[var.app_bucket_key].bucket_regional_domain_name
}

output "storage_bucket_private" {
  description = "Name of the bucket whose logical key is 'private' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["private"].id, null)
}

output "storage_bucket_private_arn" {
  description = "ARN of the bucket whose logical key is 'private' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["private"].arn, null)
}
