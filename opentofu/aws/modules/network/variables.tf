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
    Map of logical subnet name to configuration. Every subnet is sized to a /24;
    the CIDR is derived as:
      cidrsubnet(vpc_cidr, 24 - vpc_prefix, cidr_netnum)

    cidr_netnum is the /24 index within the VPC and must be in 0 .. (2^(24-vpc_prefix) - 1):
      /16 VPC -> netnum is the 3rd octet, e.g. 101 -> 10.0.101.0/24 (range 0..255)
      /22 VPC -> netnum 0..3, e.g. 0 -> 10.0.0.0/24, 1 -> 10.0.1.0/24
      /23 VPC -> netnum 0..1

    Fields:
      type              - "public" or "private" (required)
      availability_zone - AZ suffix, e.g. "a", "b", "c" (required)
      cidr_netnum       - unique /24 index, see range above (required)

    Public subnets  -> Internet Gateway route, map_public_ip_on_launch = true.
    Private subnets -> NAT Gateway route (when nat_gateway_enabled = true), no public IPs.
  EOT
  type = map(object({
    type              = string
    availability_zone = string
    cidr_netnum       = number
  }))
  default = {
    public-a = { type = "public", availability_zone = "a", cidr_netnum = 101 }
    public-b = { type = "public", availability_zone = "b", cidr_netnum = 102 }
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
  type        = bool
  default     = false
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
