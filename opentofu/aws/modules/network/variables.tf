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
    Map of logical subnet name to configuration. Each subnet may declare its own
    prefix_length (default /24); the CIDR is derived as:
      cidrsubnet(vpc_cidr, prefix_length - vpc_prefix, cidr_netnum)

    IMPORTANT: cidr_netnum indexes blocks OF THE SUBNET'S OWN SIZE, so the index
    space changes with prefix_length:
      /24 in a /22 VPC -> netnum 0..3,   e.g. 0 -> 10.0.0.0/24
      /28 in a /22 VPC -> netnum 0..63,  e.g. 32 -> 10.0.2.0/28, 33 -> 10.0.2.16/28
    A /28 at index 0 therefore overlaps a /24 at index 0. The module computes each
    subnet's real CIDR and fails (precondition in main.tf) if any two intersect, so
    you don't have to track this by hand — but pick non-overlapping blocks.

    Fields:
      type              - "public" or "private" (required)
      availability_zone - AZ suffix, e.g. "a", "b", "c" (required)
      cidr_netnum       - block index for this subnet's prefix_length (required)
      prefix_length     - subnet size, 16..28 (optional, default 24)

    Public subnets  -> Internet Gateway route, map_public_ip_on_launch = true.
    Private subnets -> NAT Gateway route (when nat_gateway_enabled = true), no public IPs.
  EOT
  type = map(object({
    type              = string
    availability_zone = string
    cidr_netnum       = number
    prefix_length     = optional(number, 24)
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

  # Overlap is validated in main.tf (needs vpc_cidr, which validation blocks can't
  # reference). Here we only bound prefix_length to AWS's allowed subnet sizes.
  validation {
    condition = alltrue([
      for k, v in var.subnet_config : v.prefix_length >= 16 && v.prefix_length <= 28
    ])
    error_message = "Each subnet 'prefix_length' must be between 16 and 28 (AWS subnet size limits)."
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
