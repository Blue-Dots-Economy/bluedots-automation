variable "environment" {
  description = "Environment name"
  type        = string
}

variable "building_block" {
  description = "Building block name"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for EKS cluster and load balancers"
  type        = list(string)
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_disk_size_gb" {
  description = "Disk size for worker nodes in GB"
  type        = number
  default     = 30
}

variable "node_count_min" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_count_max" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "node_count_desired" {
  description = "Initial desired number of worker nodes. Defaults to node_count_min when null."
  type        = number
  default     = null
}

variable "node_capacity_type" {
  description = "EC2 purchase option for the managed node group. ON_DEMAND (default, prod) or SPOT (cheaper, pilot). Changing this on an existing node group forces replacement."
  type        = string
  default     = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "ebs_csi_addon_version" {
  description = "Version of the aws-ebs-csi-driver EKS add-on (e.g. \"v1.28.0-eksbuild.1\"). Null lets AWS select the latest compatible version."
  type        = string
  default     = null
}

variable "private_ingressgateway_ip" {
  type        = string
  description = "IP of the private ingress gateway (NLB/ingress controller). Must be set by the caller after the ingress is deployed; not auto-discovered by this module."
  default     = null
}

variable "cloudwatch_enabled_log_types" {
  description = "EKS control plane log types to ship to CloudWatch Logs"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "security_group_ids" {
  description = "Security group IDs to attach to the EKS cluster"
  type        = list(string)
  default     = []
}

variable "enable_cloudwatch_observability" {
  description = "Deploy the amazon-cloudwatch-observability EKS add-on for Container Insights"
  type        = bool
  default     = false
}

variable "endpoint_public_access" {
  description = "Whether the EKS API server endpoint is publicly accessible"
  type        = bool
  default     = true
}

variable "endpoint_private_access" {
  description = "Whether the EKS API server endpoint is accessible within the VPC"
  type        = bool
  default     = false
}

variable "node_subnet_ids" {
  description = "Subnet IDs for the managed node group. When set, nodes are placed here instead of public_subnet_ids. Leave null to keep nodes in public subnets (backward-compatible default)."
  type        = list(string)
  default     = null
}
