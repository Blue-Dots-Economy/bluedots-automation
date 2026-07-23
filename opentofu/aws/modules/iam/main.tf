locals {
  environment_name = "${var.building_block}-${var.environment}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  # Exporter role is created only when a dedicated export bucket is provisioned.
  signals_export_enabled = var.signals_export_bucket != ""
}

# Application service account IRSA role
resource "aws_iam_role" "app_sa" {
  name = "${local.environment_name}-app-sa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" : var.service_account_subjects
          "${var.oidc_provider}:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${local.environment_name}-sa"
    }
  )
}

# Minimal S3 access policy for the application role
resource "aws_iam_role_policy" "app_s3" {
  name = "s3-access"
  role = aws_iam_role.app_sa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.storage_bucket_public}/*",
          "arn:aws:s3:::${var.storage_bucket_public}"
        ]
      }
    ]
  })
}

# ---------------------------------------------------------------------------------------------------------------------
# Signals S3-export exporter — dedicated least-privilege IRSA role (opt-in).
# Bound to a single service account subject and write-only on one bucket, kept
# separate from app_sa so an exporter compromise can only PUT export objects.
# Created only when var.signals_export_bucket is set.
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_role" "signals_export" {
  count = local.signals_export_enabled ? 1 : 0

  name = "${local.environment_name}-signals-s3-export"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider}:sub" : var.signals_export_sa_subject
          "${var.oidc_provider}:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${local.environment_name}-signals-s3-export"
    }
  )
}

# Write-only access to the dedicated export bucket. No ListBucket/GetObject:
# the exporter only PUTs (upload_file + put_object). AbortMultipartUpload lets
# boto3 clean up a failed multipart upload of a large NDJSON part.
resource "aws_iam_role_policy" "signals_export_s3" {
  count = local.signals_export_enabled ? 1 : 0

  name = "s3-put-export"
  role = aws_iam_role.signals_export[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = [
          "arn:aws:s3:::${var.signals_export_bucket}/*"
        ]
      }
    ]
  })
}
