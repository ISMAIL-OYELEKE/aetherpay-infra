###############################################################################
# Network ACLs: a stateless second layer under the security groups.
#
# Note on the app tier: S3/DynamoDB gateway endpoints are reached on AWS
# public prefixes, and NACLs cannot reference prefix lists, so the app NACL
# allows 443 outbound broadly. Internet access is still impossible because
# the app route tables have no default route; security groups pin egress to
# the gateway-endpoint prefix lists.
###############################################################################

locals {
  ephemeral_from = 1024
  ephemeral_to   = 65535
}

# ---------------------------------------------------------------- public tier
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.public[*].id
  tags       = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_network_acl_rule" "public_in_https" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 100
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "public_in_ephemeral_from_app" {
  # Responses from targets back to the ALB.
  count = 3

  network_acl_id = aws_network_acl.public.id
  rule_number    = 110 + count.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidrs[count.index]
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

resource "aws_network_acl_rule" "public_in_ephemeral_nat" {
  # Internet return traffic for NAT, only when NAT is enabled.
  #checkov:skip=CKV_AWS_231:Stateless return path for NAT; no listener exists on 3389 and SGs are stateful.
  count = var.enable_nat_gateway ? 1 : 0

  network_acl_id = aws_network_acl.public.id
  rule_number    = 120
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

resource "aws_network_acl_rule" "public_out_to_app" {
  count = 3

  network_acl_id = aws_network_acl.public.id
  rule_number    = 100 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidrs[count.index]
  from_port      = var.app_port
  to_port        = var.app_port
}

resource "aws_network_acl_rule" "public_out_ephemeral" {
  network_acl_id = aws_network_acl.public.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

resource "aws_network_acl_rule" "public_out_https" {
  # NAT gateways forward allow-listed app egress on 443.
  count = var.enable_nat_gateway ? 1 : 0

  network_acl_id = aws_network_acl.public.id
  rule_number    = 210
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

# ------------------------------------------------------------------- app tier
resource "aws_network_acl" "app" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.app[*].id
  tags       = merge(local.tags, { Name = "${var.name}-app" })
}

resource "aws_network_acl_rule" "app_in_from_public" {
  count = 3

  network_acl_id = aws_network_acl.app.id
  rule_number    = 100 + count.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.public_cidrs[count.index]
  from_port      = var.app_port
  to_port        = var.app_port
}

resource "aws_network_acl_rule" "app_in_ephemeral" {
  # Return traffic from the isolated tier, interface endpoints and gateway endpoints.
  #checkov:skip=CKV_AWS_231:Stateless return path from S3/DynamoDB gateway endpoints (public prefixes); nothing listens on 3389 and SGs block it.
  network_acl_id = aws_network_acl.app.id
  rule_number    = 200
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

locals {
  app_data_egress = {
    for pair in setproduct(range(3), var.data_ports) :
    "${pair[0]}-${pair[1]}" => { cidr = local.isolated_cidrs[pair[0]], port = pair[1] }
  }
  app_data_egress_keys = sort(keys(local.app_data_egress))
}

resource "aws_network_acl_rule" "app_out_data" {
  for_each = local.app_data_egress

  network_acl_id = aws_network_acl.app.id
  rule_number    = 100 + index(local.app_data_egress_keys, each.key)
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.port
  to_port        = each.value.port
}

resource "aws_network_acl_rule" "app_out_https" {
  # Interface endpoints (isolated tier) and S3/DynamoDB gateway endpoints.
  network_acl_id = aws_network_acl.app.id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "app_out_ephemeral_to_public" {
  count = 3

  network_acl_id = aws_network_acl.app.id
  rule_number    = 300 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.public_cidrs[count.index]
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

# -------------------------------------------------------------- isolated tier
resource "aws_network_acl" "isolated" {
  vpc_id     = aws_vpc.this.id
  subnet_ids = aws_subnet.isolated[*].id
  tags       = merge(local.tags, { Name = "${var.name}-isolated" })
}

locals {
  isolated_ingress = merge(
    {
      for pair in setproduct(range(3), concat(var.data_ports, [443])) :
      "app-${pair[0]}-${pair[1]}" => { cidr = local.app_cidrs[pair[0]], port = pair[1] }
    },
    {
      # Replication between cache nodes inside the isolated tier.
      for i in range(3) : "iso-${i}-6379" => { cidr = local.isolated_cidrs[i], port = 6379 }
    },
  )
  isolated_ingress_keys = sort(keys(local.isolated_ingress))
}

resource "aws_network_acl_rule" "isolated_in" {
  for_each = local.isolated_ingress

  network_acl_id = aws_network_acl.isolated.id
  rule_number    = 100 + index(local.isolated_ingress_keys, each.key)
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.port
  to_port        = each.value.port
}

resource "aws_network_acl_rule" "isolated_in_ephemeral_from_isolated" {
  count = 3

  network_acl_id = aws_network_acl.isolated.id
  rule_number    = 200 + count.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.isolated_cidrs[count.index]
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

resource "aws_network_acl_rule" "isolated_out_ephemeral_to_app" {
  count = 3

  network_acl_id = aws_network_acl.isolated.id
  rule_number    = 100 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidrs[count.index]
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

resource "aws_network_acl_rule" "isolated_out_within_tier" {
  count = 3

  network_acl_id = aws_network_acl.isolated.id
  rule_number    = 200 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.isolated_cidrs[count.index]
  from_port      = local.ephemeral_from
  to_port        = local.ephemeral_to
}

resource "aws_network_acl_rule" "isolated_out_replication" {
  count = 3

  network_acl_id = aws_network_acl.isolated.id
  rule_number    = 300 + count.index
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.isolated_cidrs[count.index]
  from_port      = 6379
  to_port        = 6379
}
