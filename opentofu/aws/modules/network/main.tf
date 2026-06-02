# ---------------------------------------------------------------------------------------------------------------------
# Locals — derived sub-maps that drive conditional resources
# ---------------------------------------------------------------------------------------------------------------------

locals {
  environment_name = "${var.building_block}-${var.environment}"

  common_tags = {
    Environment   = var.environment
    BuildingBlock = var.building_block
    ManagedBy     = "Terraform"
    CloudProvider = "AWS"
  }

  public_subnets  = { for k, v in var.subnet_config : k => v if v.type == "public" }
  private_subnets = { for k, v in var.subnet_config : k => v if v.type == "private" }

  # NAT Gateway is created only when private subnets exist, nat_gateway_enabled is true,
  # and at least one public subnet exists to host it.
  create_nat_gw = (
    var.create_network &&
    var.nat_gateway_enabled &&
    length(local.private_subnets) > 0 &&
    length(local.public_subnets) > 0
  )

  # Pick the first public subnet (sorted for determinism) to host the NAT Gateway.
  first_public_subnet_key = length(local.public_subnets) > 0 ? sort(keys(local.public_subnets))[0] : ""
}

# ---------------------------------------------------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_vpc" "vpc" {
  count = var.create_network ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${local.environment_name}-vpc" })
}

# ---------------------------------------------------------------------------------------------------------------------
# Internet Gateway — only when at least one public subnet is requested
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_internet_gateway" "igw" {
  count = var.create_network && length(local.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc[0].id

  tags = merge(local.common_tags, { Name = "${local.environment_name}-igw" })
}

# ---------------------------------------------------------------------------------------------------------------------
# Subnets — single resource block drives all entries in var.subnet_config
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_subnet" "this" {
  for_each = var.create_network ? var.subnet_config : {}

  vpc_id                  = aws_vpc.vpc[0].id
  cidr_block              = cidrsubnet(aws_vpc.vpc[0].cidr_block, 8, each.value.cidr_netnum)
  availability_zone       = "${var.aws_region}${each.value.availability_zone}"
  map_public_ip_on_launch = each.value.type == "public"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.environment_name}-${each.key}-subnet"
      Tier = each.value.type == "public" ? "Public" : "Private"
      # EKS load-balancer discovery tags
      "kubernetes.io/role/elb"                                    = each.value.type == "public" ? "1" : "0"
      "kubernetes.io/role/internal-elb"                           = each.value.type == "private" ? "1" : "0"
      "kubernetes.io/cluster/${local.environment_name}-cluster"   = "shared"
    }
  )
}

# ---------------------------------------------------------------------------------------------------------------------
# Public routing — route table + associations (only when public subnets exist)
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_route_table" "public" {
  count = var.create_network && length(local.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw[0].id
  }

  tags = merge(local.common_tags, { Name = "${local.environment_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  for_each = var.create_network ? local.public_subnets : {}

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.public[0].id
}

# ---------------------------------------------------------------------------------------------------------------------
# NAT Gateway — Elastic IP + NAT GW placed in first public subnet
# Only provisioned when: private subnets exist + nat_gateway_enabled = true + a public subnet exists
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_eip" "nat" {
  count  = local.create_nat_gw ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${local.environment_name}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  count = local.create_nat_gw ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.this[local.first_public_subnet_key].id

  tags = merge(local.common_tags, { Name = "${local.environment_name}-nat-gw" })

  depends_on = [aws_internet_gateway.igw]
}

# ---------------------------------------------------------------------------------------------------------------------
# Private routing — route table + associations (only when private subnets exist)
# The default route via NAT GW is added only when create_nat_gw is true.
# Without it, private subnets are fully isolated (valid for internal-only workloads).
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_route_table" "private" {
  count = var.create_network && length(local.private_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.vpc[0].id

  dynamic "route" {
    for_each = local.create_nat_gw ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.nat[0].id
    }
  }

  tags = merge(local.common_tags, { Name = "${local.environment_name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each = var.create_network ? local.private_subnets : {}

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[0].id
}

# ---------------------------------------------------------------------------------------------------------------------
# Security Group — HTTP/HTTPS inbound, applied at VPC level
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "allow_http_https" {
  count = var.create_network ? 1 : 0

  name        = "${local.environment_name}-allow-http-https"
  description = "Allow HTTP and HTTPS inbound traffic"
  vpc_id      = aws_vpc.vpc[0].id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidr_blocks
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidr_blocks
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.environment_name}-allow-http-https" })
}

# ---------------------------------------------------------------------------------------------------------------------
# Data sources — used when create_network = false (bring-your-own VPC)
# ---------------------------------------------------------------------------------------------------------------------

data "aws_vpc" "existing" {
  count = var.create_network ? 0 : 1
  id    = var.vpc_id
}

data "aws_subnets" "existing_public" {
  count = var.create_network ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = { Tier = "Public" }
}

data "aws_subnets" "existing_private" {
  count = var.create_network ? 0 : 1

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  tags = { Tier = "Private" }
}
