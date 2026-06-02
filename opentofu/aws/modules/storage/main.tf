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
# Bucket policy — public read applied only to public-type buckets
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_policy" "public_read" {
  for_each = local.public_buckets

  bucket = aws_s3_bucket.this[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.this[each.key].arn}/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.this]
}

# ---------------------------------------------------------------------------------------------------------------------
# CORS configuration — only applied to buckets with cors_enabled = true
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_s3_bucket_cors_configuration" "this" {
  for_each = local.cors_buckets

  bucket = aws_s3_bucket.this[each.key].id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = ["*"]
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
