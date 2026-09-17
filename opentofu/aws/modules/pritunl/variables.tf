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

variable "vpc_cidr" {
  description = "CIDR of the VPC this host sits in. Always allowed to reach SSH 22 and the web admin UI, because the VPN routes it to connected laptops — that is what keeps the admin surface reachable from home without opening it to the internet."
  type        = string
}

variable "vpn_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the OpenVPN port (1194 UDP + TCP). Defaults to the whole internet,
    which is the intended posture: Pritunl authenticates every connection with a per-user client
    certificate, so the certificate is the access control, not the source IP.

    Narrow it only where every user genuinely has a static address. A source-IP gate on 1194
    stops nobody who holds a stolen certificate, and it locks out everyone on a home, mobile or
    hotel connection the moment their ISP hands out a new lease — including, eventually, the
    office itself. Turn on per-user 2FA in Pritunl rather than reaching for this list.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_ingress_cidrs" {
  description = <<-EOT
    PUBLIC CIDRs allowed to reach the admin surface — SSH 22 and the Pritunl web admin UI on 443.
    var.vpc_cidr is always allowed on top of whatever is listed here, so leaving this empty (the
    default) still leaves both reachable on the host's PRIVATE IP to anyone already on the VPN.

    The only reason to list a public CIDR is the one-time bootstrap, before any VPN user exists
    to connect with. A stale entry here is recoverable without it: widen the security group from
    the AWS console or API, neither of which is VPN-gated.
  EOT
  type        = list(string)
  default     = []
}

variable "permissions_boundary_policy_name" {
  description = <<-EOT
    Name of an IAM policy in THIS account to attach as the permissions boundary on every role
    this module creates. Empty (the default) attaches none, which is the right answer for any
    account that does not gate role creation on a boundary.

    Set it where the DEPLOYING principal's own IAM grants are conditioned on it — Sanketika's
    `DevOpsEngineer` permission set only allows iam:CreateRole / PutRolePolicy /
    AttachRolePolicy / PassRole when the request carries the boundary, so omitting it there
    fails with "no identity-based policy allows the iam:CreateRole action". That reads like a
    missing permission but is an unmatched condition on a grant you already have.

    A policy NAME, not an ARN: a boundary must live in the same account as the role, so the
    account id is resolved from the caller and the same value works in every account. Create
    the policy with scripts/create-permissions-boundary.sh — this repo never manages it.
  EOT
  type        = string
  # Nullable so "key absent from global-values.yaml" (null) is distinguishable from
  # "operator chose no boundary" ("" ). Both attach nothing; only the first is a
  # mistake, and the check block below warns on it.
  default  = null
  nullable = true
}
