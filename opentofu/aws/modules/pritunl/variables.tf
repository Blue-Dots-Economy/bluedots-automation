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
  description = "VPC ID where the Pritunl EC2 will be placed"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID for the Pritunl EC2 (must have an internet gateway route)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Minimum t3.small — MongoDB requires ~1 GB RAM"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Optional AWS EC2 key pair name. Leave null when using authorized_keys — access is granted by the public keys injected via user_data."
  type        = string
  default     = null
}

variable "authorized_keys" {
  description = "Public SSH keys (one full line each) appended to the ubuntu user's authorized_keys, for the one-time Pritunl setup shell. Public keys only — private keys never enter Terraform state."
  type        = list(string)
  default     = []
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach the Pritunl VPN inbound ports (OpenVPN 1194 UDP/TCP, web 443, SSH 22). Default open to the internet; set to office/home CIDRs (e.g. [\"203.0.113.10/32\"]) to restrict who can even attempt to connect. This gates all downstream cluster access. NOTE: home ISP IPs are often dynamic — a changed IP locks the VPN out until you update this (recover by editing the SG via the AWS console/API, which is not VPN-gated)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
