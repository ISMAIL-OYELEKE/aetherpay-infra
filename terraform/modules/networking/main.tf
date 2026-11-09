###############################################################################
# CIDR plan for 10.24.0.0/20 (4,096 addresses), three tiers x three AZs.
#
#   Tier       Size  AZ-a             AZ-b             AZ-c             Spare
#   public     /26   10.24.0.0/26     10.24.0.64/26    10.24.0.128/26   10.24.0.192/26
#   isolated   /25   10.24.1.0/25     10.24.1.128/25   10.24.2.0/25     10.24.2.128/25
#   reserved   /24   10.24.3.0/24 (future: TGW attachments, extra endpoints)
#   app        /22   10.24.4.0/22     10.24.8.0/22     10.24.12.0/22
#
# The ranges are derived with cidrsubnet() so they can never drift from the
# VPC block, and tests/networking.tftest.hcl asserts they do not overlap.
###############################################################################

locals {
  public_cidrs   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 6, i)]     # /26 #0-2
  isolated_cidrs = [for i in range(3) : cidrsubnet(var.vpc_cidr, 5, i + 2)] # /25 #2-4
  app_cidrs      = [for i in range(3) : cidrsubnet(var.vpc_cidr, 2, i + 1)] # /22 #1-3
  all_cidrs      = concat(local.public_cidrs, local.isolated_cidrs, local.app_cidrs)

  tags = merge(var.tags, { "aetherpay:module" = "networking" })
}

data "aws_region" "current" {}

# Runtime guard (also covered by tests/networking.tftest.hcl): no two subnets
# may overlap, whatever vpc_cidr is passed in.
check "no_overlapping_subnets" {
  assert {
    condition = alltrue(flatten([
      for i, a in local.all_cidrs : [
        for j, b in local.all_cidrs :
        i == j || (
          cidrhost("${cidrhost(a, 0)}/${min(tonumber(split("/", a)[1]), tonumber(split("/", b)[1]))}", 0) !=
          cidrhost("${cidrhost(b, 0)}/${min(tonumber(split("/", a)[1]), tonumber(split("/", b)[1]))}", 0)
        )
      ]
    ]))
    error_message = "Subnet CIDRs overlap."
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = var.name })
}

# Lock down the default SG: nothing in, nothing out (CIS 5.4).
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-default-deny" })
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false # ALB/NAT get addresses explicitly; nothing else lands here.

  tags = merge(local.tags, {
    Name             = "${var.name}-public-${var.azs[count.index]}"
    "aetherpay:tier" = "public"
  })
}

resource "aws_subnet" "app" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.app_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name             = "${var.name}-app-${var.azs[count.index]}"
    "aetherpay:tier" = "app"
  })
}

resource "aws_subnet" "isolated" {
  count = 3

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.isolated_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name             = "${var.name}-isolated-${var.azs[count.index]}"
    "aetherpay:tier" = "isolated"
  })
}

###############################################################################
# Public tier: IGW + optional NAT
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = 3

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 3 : 0

  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat-${var.azs[count.index]}" })
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? 3 : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${var.name}-nat-${var.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Application tier: one route table per AZ, NO default route.
# Egress is limited to: local VPC (isolated tier + interface endpoints),
# S3/DynamoDB gateway endpoints, and (optionally) allow-listed CIDRs via NAT.
###############################################################################

resource "aws_route_table" "app" {
  count = 3

  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-app-${var.azs[count.index]}" })
}

resource "aws_route" "app_allowlisted_egress" {
  for_each = var.enable_nat_gateway ? {
    for pair in setproduct(range(3), var.nat_egress_cidrs) : "${pair[0]}-${pair[1]}" => {
      az   = pair[0]
      cidr = pair[1]
    }
  } : {}

  route_table_id         = aws_route_table.app[each.value.az].id
  destination_cidr_block = each.value.cidr
  nat_gateway_id         = aws_nat_gateway.this[each.value.az].id
}

resource "aws_route_table_association" "app" {
  count = 3

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

###############################################################################
# Isolated tier: local route only. Zero internet egress, zero NAT.
###############################################################################

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-isolated" })
}

resource "aws_route_table_association" "isolated" {
  count = 3

  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}
