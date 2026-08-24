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
# Convenience outputs for the conventional aggregator bucket (key = "private").
# Return null if that key is not present in var.buckets so callers can use try().
# The former storage_bucket_public* outputs were removed with the public bucket type:
# leaving them as null-returning aliases would let a stale consumer wire the application
# to an empty string and fail at runtime instead of at plan time.
# ---------------------------------------------------------------------------------------------------------------------

output "storage_bucket_private" {
  description = "Name of the bucket whose logical key is 'private' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["private"].id, null)
}

output "storage_bucket_private_arn" {
  description = "ARN of the bucket whose logical key is 'private' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["private"].arn, null)
}
