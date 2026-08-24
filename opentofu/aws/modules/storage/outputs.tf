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
# The former storage_bucket_public*/storage_bucket_private* convenience outputs are gone.
# They keyed on a hardcoded logical name, which is exactly what app_bucket_key replaced;
# leaving them as null-returning aliases would let a stale consumer wire the application
# to an empty string and fail at runtime instead of at plan time.
# ---------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------------------------
# The application bucket, resolved through var.app_bucket_key. Consumers (iam, output-file) use
# THIS rather than a hardcoded key, so an environment keeping its historical key needs no change
# on their side. See var.app_bucket_key for why the key is not simply "private" everywhere.
# ---------------------------------------------------------------------------------------------------------------------

output "storage_bucket_app" {
  description = "Name of the bucket the aggregator application uses (var.app_bucket_key)"
  value       = try(aws_s3_bucket.this[var.app_bucket_key].id, null)
}

output "storage_bucket_app_arn" {
  description = "ARN of the bucket the aggregator application uses (var.app_bucket_key)"
  value       = try(aws_s3_bucket.this[var.app_bucket_key].arn, null)
}
