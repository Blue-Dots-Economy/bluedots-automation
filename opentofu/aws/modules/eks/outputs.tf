output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.cluster.id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.cluster.name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.cluster.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.cluster.certificate_authority[0].data
  sensitive   = true
}

output "cluster_arn" {
  description = "The Amazon Resource Name (ARN) of the cluster"
  value       = aws_eks_cluster.cluster.arn
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS"
  value       = aws_iam_openid_connect_provider.oidc.arn
}

output "oidc_provider" {
  description = "The OpenID Connect identity provider (without https://)"
  value       = replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role arn for worker nodes"
  value       = aws_iam_role.eks_node.arn
}

output "private_lb_ip" {
  description = "Private load balancer IP"
  value       = var.private_ingressgateway_ip
}

output "cloudwatch_observability_role_arn" {
  description = "IAM role ARN used by the CloudWatch Observability add-on"
  value       = var.enable_cloudwatch_observability ? aws_iam_role.cloudwatch_observability[0].arn : null
}
