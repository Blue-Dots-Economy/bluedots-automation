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
  description = "Optional AWS EC2 key pair name. Leave null when using authorized_keys (the recommended path) — access is then granted purely by the public keys injected via user_data."
  type        = string
  default     = null
}

variable "authorized_keys" {
  description = "Public SSH keys (one full line each, e.g. 'ssh-ed25519 AAAA... alice') appended to ec2-user's authorized_keys. Each developer generates their own key pair with ssh-keygen and shares only the public half; private keys never enter Terraform or state. Add/remove entries to grant/revoke access."
  type        = list(string)
  default     = []
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
