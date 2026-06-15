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

variable "create_network" {
  description = "Whether to create a new VPC (true) or use existing (false)"
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_config" {
  description = <<-EOT
    Map of logical subnet name to configuration. Each subnet is always /24 (256 IPs).
    The CIDR is derived as: cidrsubnet(vpc_cidr, 24 - vpc_prefix, cidr_netnum)

    Fields:
      type              - "public" or "private" (required)
      availability_zone - AZ suffix, e.g. "a", "b", "c" (required)
      cidr_netnum       - sequential index starting at 0 (required, must be unique)
                          Max valid value = 2^(24 - vpc_prefix) - 1
                          e.g. /22 VPC → max 3 | /20 → max 15 | /16 → max 255

    Public subnets  -> Internet Gateway route, map_public_ip_on_launch = true.
    Private subnets -> NAT Gateway route (when nat_gateway_enabled = true), no public IPs.
  EOT
  type = map(object({
    type              = string
    availability_zone = string
    cidr_netnum       = number
  }))
  default = {
    public-a = { type = "public", availability_zone = "a", cidr_netnum = 0 }
    public-b = { type = "public", availability_zone = "b", cidr_netnum = 1 }
  }

  validation {
    condition = alltrue([
      for k, v in var.subnet_config : contains(["public", "private"], v.type)
    ])
    error_message = "Each subnet 'type' must be either \"public\" or \"private\"."
  }

  validation {
    condition = length(var.subnet_config) == length(distinct([
      for k, v in var.subnet_config : v.cidr_netnum
    ]))
    error_message = "Each subnet must have a unique cidr_netnum to avoid CIDR conflicts."
  }
}

variable "nat_gateway_enabled" {
  description = <<-EOT
    Create a NAT Gateway so private subnets can reach the internet.
    Requires at least one public subnet (NAT GW is placed in the first public subnet).

    Defaults to false. Set to true only when private subnets need outbound internet access
    (e.g. pulling container images, calling external APIs). Each NAT Gateway incurs ~$32/month
    per AZ in additional AWS charges — opt in explicitly rather than enabling it by default.

    Has no effect when no private subnets are defined.
  EOT
  type    = bool
  default = false
}

variable "ingress_cidr_blocks" {
  description = "CIDR blocks allowed for HTTP/HTTPS inbound traffic on the shared security group"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "vpc_id" {
  description = "Existing VPC ID (required if create_network is false)"
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs (required if create_network is false)"
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs (required if create_network is false)"
  type        = list(string)
  default     = []
}
