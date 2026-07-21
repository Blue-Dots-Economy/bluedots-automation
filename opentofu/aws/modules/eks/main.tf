locals {
  environment_name = "${var.building_block}-${var.environment}"
  cluster_name     = "${local.environment_name}-cluster"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }
}

# -------------------------------
# IAM roles and policies
# -------------------------------

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.building_block}-${var.environment}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSServicePolicy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.building_block}-${var.environment}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# -------------------------------
# EKS Cluster
# -------------------------------

resource "aws_eks_cluster" "cluster" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = var.public_subnet_ids
    security_group_ids      = var.security_group_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
  }

  enabled_cluster_log_types = var.cloudwatch_enabled_log_types

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  tags = merge(local.common_tags, { Name = local.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSServicePolicy
  ]
}

# -------------------------------
# OIDC provider for IRSA
# -------------------------------

# The TLS data source returns cert information for the OIDC issuer.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# -------------------------------
# EKS Managed Node Group
# -------------------------------

# Why random_id keepers?
# AWS does not support in-place changes to instance_type or disk_size on a managed node group —
# it must be destroyed and recreated. The random_id keepers tie the hex suffix to these two
# values, so changing either one forces a new random_id (and therefore a new node group name).
# create_before_destroy = true ensures the replacement group is running before the old one
# is deleted, but expect a brief period of reduced capacity during the transition.
#
# IMPORTANT: Draining workloads before changing instance_type or disk_size is strongly
# recommended to avoid application downtime. See MODULES.md § EKS for the procedure.
resource "random_id" "node_group" {
  byte_length = 4
  keepers = {
    instance_type = var.node_instance_type
    disk_size     = var.node_disk_size_gb
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = "${local.cluster_name}-ng-${random_id.node_group.hex}"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = var.node_subnet_ids != null ? var.node_subnet_ids : var.public_subnet_ids

  scaling_config {
    desired_size = coalesce(var.node_count_desired, var.node_count_min)
    min_size     = var.node_count_min
    max_size     = var.node_count_max
  }

  instance_types = [var.node_instance_type]
  capacity_type  = var.node_capacity_type
  disk_size      = var.node_disk_size_gb

  tags = merge(
    local.common_tags,
    { Name = "${local.cluster_name}-node" }
  )

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_openid_connect_provider.oidc
  ]

  lifecycle {
    create_before_destroy = true
  }

  # Give AWS enough time to provision or drain nodes during create-before-destroy replacements.
  # Default timeouts are often too short when replacing a large node group.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}

# -------------------------------
# EBS CSI Driver IRSA role (reuse existing module)
# module expects an OIDC provider ARN
# -------------------------------

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name_prefix = "${local.cluster_name}-ebs-csi-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.oidc.arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}
# -------------------------------
# EKS Add-on: AWS EBS CSI Driver
# Installs the aws-ebs-csi-driver addon and binds it to the IRSA role
# -------------------------------

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.cluster.name
  addon_name   = "aws-ebs-csi-driver"

  # Use the IRSA role created above for the controller service account
  service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn

  # Pin to a specific version or leave null to let AWS pick the latest compatible version
  addon_version = var.ebs_csi_addon_version

  # Ensure the addon can reconcile any existing resources
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [
    module.ebs_csi_driver_irsa,
    aws_eks_cluster.cluster,
    aws_eks_node_group.default
  ]
}

# -------------------------------
# CloudWatch Observability (Container Insights)
# -------------------------------

resource "aws_iam_role" "cloudwatch_observability" {
  count = var.enable_cloudwatch_observability ? 1 : 0

  name = "${local.cluster_name}-cw-obs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.oidc.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
            "${replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability_policy" {
  count      = var.enable_cloudwatch_observability ? 1 : 0
  role       = aws_iam_role.cloudwatch_observability[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count        = var.enable_cloudwatch_observability ? 1 : 0
  cluster_name = aws_eks_cluster.cluster.name
  addon_name   = "amazon-cloudwatch-observability"

  service_account_role_arn    = aws_iam_role.cloudwatch_observability[0].arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.common_tags

  depends_on = [
    aws_eks_cluster.cluster,
    aws_eks_node_group.default,
    aws_iam_role_policy_attachment.cloudwatch_observability_policy
  ]
}
