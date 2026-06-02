locals {
  environment_name = "${var.building_block}-${var.environment}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }
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
