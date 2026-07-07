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

  # VPC prefix length (e.g. 22 for 10.0.0.0/22).
  vpc_prefix = tonumber(split("/", var.vpc_cidr)[1])

  # Per-subnet CIDR. Each subnet declares its own prefix_length (default /24); the
  # bits added to the VPC prefix are derived from it, so subnets of different sizes
  # can coexist in one VPC:
  #   /24 in a /22 → +2 newbits, cidr_netnum is the /24 index (0..3)
  #   /28 in a /22 → +6 newbits, cidr_netnum is the /28 index (0..63)
  # NOTE: cidr_netnum indexes blocks OF THE SUBNET'S OWN SIZE, so a /28 at index 0
  # overlaps a /24 at index 0. The overlap precondition below guards against this.
  subnet_cidrs = {
    for k, v in var.subnet_config :
    k => cidrsubnet(var.vpc_cidr, v.prefix_length - local.vpc_prefix, v.cidr_netnum)
  }

  # Numeric [start, start+size) range of each subnet block, for overlap detection.
  # IPv4 dotted-quad → 32-bit integer; size = address count for the subnet's prefix.
  subnet_ranges = {
    for k, c in local.subnet_cidrs :
    k => {
      start = (
        tonumber(split(".", cidrhost(c, 0))[0]) * 16777216 +
        tonumber(split(".", cidrhost(c, 0))[1]) * 65536 +
        tonumber(split(".", cidrhost(c, 0))[2]) * 256 +
        tonumber(split(".", cidrhost(c, 0))[3])
      )
      size = pow(2, 32 - tonumber(split("/", c)[1]))
    }
  }

  # Unordered subnet pairs whose ranges intersect. Must be empty (see precondition
  # on aws_subnet.this). Replaces the old cidr_netnum-uniqueness check, which could
  # not detect overlaps between subnets of different prefix lengths.
  # Enumerate with numeric indices (i < j) — OpenTofu's "<" is numeric-only, so we
  # can't compare key strings directly. i < j gives unique unordered pairs and skips
  # self-pairs in one shot.
  subnet_keys = keys(var.subnet_config)
  subnet_overlaps = flatten([
    for i, ka in local.subnet_keys : [
      for j, kb in local.subnet_keys :
      "${ka} <-> ${kb}"
      if i < j &&
      local.subnet_ranges[ka].start < local.subnet_ranges[kb].start + local.subnet_ranges[kb].size &&
      local.subnet_ranges[kb].start < local.subnet_ranges[ka].start + local.subnet_ranges[ka].size
    ]
  ])

  # NAT Gateway is created only when private subnets exist, nat_gateway_enabled is true,
  # and at least one public subnet exists to host it.
  create_nat_gw = (
    var.create_network &&
    var.nat_gateway_enabled &&
    length(local.private_subnets) > 0 &&
    length(local.public_subnets) > 0
  )

  # Pick the first public subnet (sorted for determinism) — used as fallback NAT GW key.
  first_public_subnet_key = length(local.public_subnets) > 0 ? sort(keys(local.public_subnets))[0] : ""

  # Map from AZ letter → first public subnet key in that AZ.
  # Lets each private subnet route through its own AZ's NAT GW.
  az_to_public_subnet = {
    for k, v in local.public_subnets : v.availability_zone => k
  }

  # For each private subnet: which public-subnet key's NAT GW should it use?
  # Matches by AZ letter; falls back to first public subnet when no same-AZ public subnet exists.
  private_subnet_nat_key = {
    for k, v in local.private_subnets :
    k => try(local.az_to_public_subnet[v.availability_zone], local.first_public_subnet_key)
  }
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
  cidr_block              = local.subnet_cidrs[each.key]
  availability_zone       = "${var.aws_region}${each.value.availability_zone}"
  map_public_ip_on_launch = each.value.type == "public"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.environment_name}-${each.key}-subnet"
      Tier = each.value.type == "public" ? "Public" : "Private"
      # EKS load-balancer discovery tags
      "kubernetes.io/role/elb"                                  = each.value.type == "public" ? "1" : "0"
      "kubernetes.io/role/internal-elb"                         = each.value.type == "private" ? "1" : "0"
      "kubernetes.io/cluster/${local.environment_name}-cluster" = "shared"
    }
  )

  lifecycle {
    precondition {
      condition     = length(local.subnet_overlaps) == 0
      error_message = "subnet_config has overlapping CIDR blocks: ${join(", ", local.subnet_overlaps)}. Adjust cidr_netnum / prefix_length so the blocks do not intersect."
    }
  }
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
# NAT Gateway — one per public subnet (one per AZ) for HA
# Only provisioned when: private subnets exist + nat_gateway_enabled = true + a public subnet exists
# One NAT GW per AZ means: if AZ-a fails, nodes in AZ-b still have outbound internet.
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_eip" "nat" {
  for_each = local.create_nat_gw ? local.public_subnets : {}
  domain   = "vpc"

  tags = merge(local.common_tags, { Name = "${local.environment_name}-${each.key}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  for_each = local.create_nat_gw ? local.public_subnets : {}

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.this[each.key].id

  tags = merge(local.common_tags, { Name = "${local.environment_name}-${each.key}-nat-gw" })

  depends_on = [aws_internet_gateway.igw]
}

# ---------------------------------------------------------------------------------------------------------------------
# Private routing — one route table per private subnet
# Each private subnet routes through the NAT GW in its own AZ (local.private_subnet_nat_key).
# Without nat_gw, private subnets are fully isolated (valid for internal-only workloads).
# ---------------------------------------------------------------------------------------------------------------------

resource "aws_route_table" "private" {
  for_each = var.create_network && length(local.private_subnets) > 0 ? local.private_subnets : {}

  vpc_id = aws_vpc.vpc[0].id

  dynamic "route" {
    for_each = local.create_nat_gw ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.nat[local.private_subnet_nat_key[each.key]].id
    }
  }

  tags = merge(local.common_tags, { Name = "${local.environment_name}-${each.key}-private-rt" })
}

resource "aws_route_table_association" "private" {
  for_each = var.create_network ? local.private_subnets : {}

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private[each.key].id
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
