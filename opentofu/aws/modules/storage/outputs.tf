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

output "storage_bucket_public" {
  description = "Name of the bucket whose logical key is 'public' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["public"].id, null)
}

output "storage_bucket_public_arn" {
  description = "ARN of the bucket whose logical key is 'public' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["public"].arn, null)
}

output "storage_bucket_public_domain" {
  description = "Regional domain of the bucket whose logical key is 'public' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["public"].bucket_regional_domain_name, null)
}

output "storage_bucket_private" {
  description = "Name of the bucket whose logical key is 'private' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["private"].id, null)
}

output "storage_bucket_private_arn" {
  description = "ARN of the bucket whose logical key is 'private' (null if not provisioned)"
  value       = try(aws_s3_bucket.this["private"].arn, null)
}
