locals {
  environment_name = "${var.building_block}-${var.environment}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  # Permissions boundary attached to every role below. Empty var = null = argument omitted, so
  # the modules work unchanged in an account with no boundary requirement. Where the deploying
  # principal's IAM grants ARE conditioned on it, omitting it fails as "no identity-based policy
  # allows iam:CreateRole" — an unmatched conditional Allow, not a missing permission.
  # Account id and partition come from the caller so one name works in every account/partition.
  # The policy itself is never managed here; see scripts/create-permissions-boundary.sh.
  permissions_boundary = var.permissions_boundary_policy_name != "" ? format(
    "arn:%s:iam::%s:policy/%s",
    data.aws_partition.current.partition,
    data.aws_caller_identity.current.account_id,
    var.permissions_boundary_policy_name,
  ) : null
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# Application service account IRSA role
resource "aws_iam_role" "app_sa" {
  name                 = "${local.environment_name}-app-sa"
  permissions_boundary = local.permissions_boundary

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

# Minimal S3 access policy for the application role.
# Shared by every subject in var.service_account_subjects — the aggregator
# api/worker AND the signals s3-export CronJob, which writes its non-PII export
# objects into this same bucket rather than a dedicated one.
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

# NOTE: the Signals s3-export CronJob used to get its own least-privilege IRSA
# role (`<env>-signals-s3-export`, write-only on a dedicated private bucket).
# Both were removed: the exporter now shares the public bucket and the app_sa
# role above, so its ServiceAccount subject must be listed in
# var.service_account_subjects or the pod cannot assume the role at all.
