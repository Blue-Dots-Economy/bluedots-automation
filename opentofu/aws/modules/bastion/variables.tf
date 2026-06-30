variable "environment" {
  type = string
}

variable "building_block" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block — used to restrict SSH ingress to VPC-internal traffic only."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID for the bastion. No public IP is assigned — bastion is only reachable after connecting Pritunl VPN."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. Create one first: AWS console → EC2 → Key Pairs → Create key pair. Download and chmod 400 the .pem file."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. The bastion's IAM role is mapped into this cluster via an EKS access entry so kubectl/helm from the bastion pass Kubernetes RBAC."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium (4 GB) is the floor — the bastion runs helm/kubectl deployments and `helm template` of the umbrella charts OOMs on smaller boxes."
  type        = string
  default     = "t3.medium"
}
