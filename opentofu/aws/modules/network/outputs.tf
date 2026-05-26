# ---------------------------------------------------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = var.create_network ? aws_vpc.vpc[0].id : data.aws_vpc.existing[0].id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = var.create_network ? aws_vpc.vpc[0].cidr_block : data.aws_vpc.existing[0].cidr_block
}

# ---------------------------------------------------------------------------------------------------------------------
# Generic subnet map — all provisioned subnets keyed by logical name (same key as var.subnet_config)
# ---------------------------------------------------------------------------------------------------------------------

output "subnets" {
  description = "All provisioned subnets keyed by logical name (same key as var.subnet_config)"
  value = {
    for k, s in aws_subnet.this : k => {
      id                = s.id
      arn               = s.arn
      cidr_block        = s.cidr_block
      availability_zone = s.availability_zone
      type              = var.subnet_config[k].type
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# Convenience outputs — backward-compatible lists consumed by eks, _common/eks.hcl
# ---------------------------------------------------------------------------------------------------------------------

output "public_subnet_ids" {
  description = "IDs of all public subnets (new VPC) or fetched from existing VPC"
  value = var.create_network ? [
    for k, s in aws_subnet.this : s.id if var.subnet_config[k].type == "public"
  ] : data.aws_subnets.existing_public[0].ids
}

output "private_subnet_ids" {
  description = "IDs of all private subnets (new VPC) or fetched from existing VPC"
  value = var.create_network ? [
    for k, s in aws_subnet.this : s.id if var.subnet_config[k].type == "private"
  ] : data.aws_subnets.existing_private[0].ids
}

# ---------------------------------------------------------------------------------------------------------------------
# Routing / gateway outputs
# ---------------------------------------------------------------------------------------------------------------------

output "internet_gateway_id" {
  description = "Internet Gateway ID (null if no public subnets)"
  value       = length(aws_internet_gateway.igw) > 0 ? aws_internet_gateway.igw[0].id : null
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (null if not created)"
  value       = length(aws_nat_gateway.nat) > 0 ? aws_nat_gateway.nat[0].id : null
}

output "nat_gateway_public_ip" {
  description = "Elastic IP assigned to the NAT Gateway (null if not created)"
  value       = length(aws_eip.nat) > 0 ? aws_eip.nat[0].public_ip : null
}

output "public_route_table_id" {
  description = "Public route table ID (null if no public subnets)"
  value       = length(aws_route_table.public) > 0 ? aws_route_table.public[0].id : null
}

output "private_route_table_id" {
  description = "Private route table ID (null if no private subnets)"
  value       = length(aws_route_table.private) > 0 ? aws_route_table.private[0].id : null
}

# ---------------------------------------------------------------------------------------------------------------------
# Security group
# ---------------------------------------------------------------------------------------------------------------------

output "security_group_id" {
  description = "Security group ID for HTTP/HTTPS traffic (null if create_network = false)"
  value       = length(aws_security_group.allow_http_https) > 0 ? aws_security_group.allow_http_https[0].id : null
}
