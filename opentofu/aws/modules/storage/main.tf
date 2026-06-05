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
  public_buckets    = { for k, v in var.buckets : k => v if v.type == "public" }
  cors_buckets      = { for k, v in var.buckets : k => v if v.cors_enabled }
  versioned_buckets = { for k, v in var.buckets : k => v if v.versioning_enabled }

  # CORS origins fall back to the configured referers (stripped of any path suffix) so that a
  # cors_enabled bucket is never left wide open when only allowed_referers is supplied.
  effective_cors_origins = length(var.cors_allowed_origins) > 0 ? var.cors_allowed_origins : [
    for r in var.allowed_referers : replace(r, "/\\/\\*$/", "")
  ]
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
# Public-access block — private buckets are fully blocked, public buckets are open
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  block_public_acls       = each.value.type == "private"
  block_public_policy     = each.value.type == "private"
  ignore_public_acls      = each.value.type == "private"
  restrict_public_buckets = each.value.type == "private"
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
# Bucket policy — one policy per bucket, combining:
#   1. DenyInsecureTransport  : reject any request not over TLS (applies to ALL buckets)
#   2. PublicReadGetObject    : public buckets only; scoped to allowed_referers when provided
# S3 permits a single bucket policy per bucket, so both statements must live in one resource.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "this" {
  for_each = var.buckets

  bucket = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
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
      ],
      each.value.type == "public" ? [
        merge(
          {
            Sid       = "PublicReadGetObject"
            Effect    = "Allow"
            Principal = "*"
            Action    = "s3:GetObject"
            Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
          },
          length(var.allowed_referers) > 0 ? {
            Condition = {
              StringLike = { "aws:Referer" = var.allowed_referers }
            }
          } : {}
        ),
      ] : []
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------------------------------------------------
# CORS configuration — only applied to buckets with cors_enabled = true.
# Origins are restricted to effective_cors_origins (never "*"); a cors_enabled bucket with no
# configured origins gets no CORS rule at all rather than a wide-open one.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_cors_configuration" "this" {
  for_each = {
    for k, v in local.cors_buckets : k => v if length(local.effective_cors_origins) > 0
  }

  bucket = aws_s3_bucket.this[each.key].id

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
