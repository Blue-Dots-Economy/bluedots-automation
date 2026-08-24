# Get AWS account ID
data "aws_caller_identity" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  environment_name = "${var.building_block}-${var.environment}"
  bucket_prefix    = "${local.environment_name}-${local.account_id}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  # Derived sub-maps used by conditional resources
  cors_buckets      = { for k, v in var.buckets : k => v if v.cors_enabled }
  versioned_buckets = { for k, v in var.buckets : k => v if v.versioning_enabled }

  # cors_allowed_origins is now the SOLE source of CORS origins (the referer
  # fallback went with the public-read policy). A cors_enabled bucket with no
  # origins gets no rule, which breaks browser uploads — hence the precondition
  # on the CORS resource below rather than a silent empty allow-list.
  effective_cors_origins = var.cors_allowed_origins

  # Buckets that declare at least one non-zero retention window.
  lifecycle_buckets = {
    for k, v in var.buckets : k => v
    if length([for days in values(v.lifecycle_rules) : days if days != null && days > 0]) > 0
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# S3 Buckets — one resource block drives all entries in var.buckets
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  for_each = var.buckets

  bucket = "${local.bucket_prefix}-${each.key}"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.bucket_prefix}-${each.key}"
      Type = each.value.type
    }
  )
}

# ---------------------------------------------------------------------------------------------------------------------
# Public-access block — unconditional. Every bucket is fully blocked from public access.
# These are hardcoded rather than derived from `type`: a bucket whose access posture can be
# flipped by a config value is one config edit away from re-exposing participant PII.
# Pre-signed URLs are authenticated requests and are unaffected by these settings.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------------------------------------------------
# Server-side encryption — SSE-S3 (AES256) enforced on every bucket so objects are encrypted at rest
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Bucket policy — DenyInsecureTransport only: reject any request not over TLS.
#
# The former PublicReadGetObject statement (Principal "*", scoped by aws:Referer) is gone.
# aws:Referer is a request header any client can set, so it was not an access control at all.
# Reads and writes are now authorised per-object by a pre-signed URL minted by the API.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.this[each.key].arn,
          "${aws_s3_bucket.this[each.key].arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------------------------------------------------
# CORS configuration — only applied to buckets with cors_enabled = true.
# Origins are restricted to effective_cors_origins (never "*"); a cors_enabled bucket with no
# configured origins gets no CORS rule at all rather than a wide-open one.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_cors_configuration" "this" {
  for_each = local.cors_buckets

  bucket = aws_s3_bucket.this[each.key].id

  # Fail the plan rather than provision a cors_enabled bucket with no rule. A
  # missing CORS rule breaks every browser pre-signed PUT at preflight, and the
  # resulting error looks like anything except "aggregator_host is unset".
  lifecycle {
    precondition {
      condition     = length(local.effective_cors_origins) > 0
      error_message = "Bucket '${each.key}' has cors_enabled but no cors_allowed_origins were supplied. Set global.aggregator_host in global-values.yaml — browsers cannot complete a pre-signed upload without a CORS rule."
    }
  }

  cors_rule {
    allowed_headers = var.cors_allowed_headers
    allowed_methods = var.cors_allowed_methods
    allowed_origins = local.effective_cors_origins
    expose_headers  = ["ETag"]
    max_age_seconds = var.cors_max_age_seconds
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Versioning — only applied to buckets with versioning_enabled = true
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.versioned_buckets

  bucket = aws_s3_bucket.this[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Lifecycle — per-prefix expiry for transient objects.
#
# Retention is a deployment-time value (see var.buckets.lifecycle_rules); 0/unset renders no rule
# for that prefix. Two things here are load-bearing and easy to omit:
#
#   1. noncurrent_version_expiration alongside every expiration. On an UNVERSIONED bucket (which is
#      how the aggregator bucket is deployed today) a plain expiration permanently deletes and the
#      noncurrent rule is an accepted no-op. The moment versioning is enabled, though, an
#      expiration-only rule merely writes a delete marker and keeps the object body — and therefore
#      the participant PII — as a noncurrent version FOREVER: configured-looking, deleting nothing.
#      Both are rendered unconditionally so enabling versioning later cannot silently reintroduce
#      that. Do not "simplify" by dropping the noncurrent rule because the current bucket is
#      unversioned.
#   2. abort_incomplete_multipart_upload. An abandoned browser PUT leaves parts that are billable
#      and invisible to ListObjects.
#
# `qr/` is deliberately absent: QR PNGs are durable. A printed QR code outlives any retention
# window, so expiring the object breaks physical collateral already in the field.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = local.lifecycle_buckets

  bucket = aws_s3_bucket.this[each.key].id

  # Raw participant CSVs — highest-PII object we hold, so the shortest life.
  dynamic "rule" {
    for_each = each.value.lifecycle_rules.uploads_raw_retention_days > 0 ? [1] : []
    content {
      id     = "expire-uploads-raw"
      status = "Enabled"
      filter {
        prefix = "uploads/raw/"
      }
      expiration {
        days = each.value.lifecycle_rules.uploads_raw_retention_days
      }
      noncurrent_version_expiration {
        noncurrent_days = each.value.lifecycle_rules.uploads_raw_retention_days
      }
    }
  }

  # Generated error reports — the aggregator's own worklist for fixing rejected rows.
  dynamic "rule" {
    for_each = each.value.lifecycle_rules.uploads_errors_retention_days > 0 ? [1] : []
    content {
      id     = "expire-uploads-errors"
      status = "Enabled"
      filter {
        prefix = "uploads/errors/"
      }
      expiration {
        days = each.value.lifecycle_rules.uploads_errors_retention_days
      }
      noncurrent_version_expiration {
        noncurrent_days = each.value.lifecycle_rules.uploads_errors_retention_days
      }
    }
  }

  # Pre-migration keys (raw CSVs and error reports both lived under bulk-uploads/).
  # Retire this rule once the window has elapsed and no rows reference the old layout.
  dynamic "rule" {
    for_each = each.value.lifecycle_rules.legacy_bulk_retention_days > 0 ? [1] : []
    content {
      id     = "expire-legacy-bulk-uploads"
      status = "Enabled"
      filter {
        prefix = "bulk-uploads/"
      }
      expiration {
        days = each.value.lifecycle_rules.legacy_bulk_retention_days
      }
      noncurrent_version_expiration {
        noncurrent_days = each.value.lifecycle_rules.legacy_bulk_retention_days
      }
    }
  }

  # Abandoned multipart uploads, bucket-wide.
  dynamic "rule" {
    for_each = each.value.lifecycle_rules.abort_incomplete_mpu_days > 0 ? [1] : []
    content {
      id     = "abort-incomplete-multipart-uploads"
      status = "Enabled"
      filter {}
      abort_incomplete_multipart_upload {
        days_after_initiation = each.value.lifecycle_rules.abort_incomplete_mpu_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.this]
}
