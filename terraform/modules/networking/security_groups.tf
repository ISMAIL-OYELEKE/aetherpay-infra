###############################################################################
# Security group matrix (the whole east-west policy in one place).
#
#   internet --443--> alb --app_port--> app --5432--> db
#                                        |---6379--> cache (+ cache<->cache)
#                                        |---443---> interface endpoints
#                                        '---443---> S3 / DynamoDB prefix lists
#
# No security group has a 0.0.0.0/0 egress rule.
###############################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Public ALB: TLS from partners, forwards to app tier only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-app-"
  description = "Application tier workloads (no public IPs)"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-app" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-db-"
  description = "Aurora PostgreSQL in the isolated tier"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "cache" {
  name_prefix = "${var.name}-cache-"
  description = "ElastiCache (Valkey) in the isolated tier"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${var.name}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------ ALB
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "TLS 1.3 webhooks from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to app tier"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# ------------------------------------------------------------------------ app
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "Traffic from the ALB only"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to Aurora"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_cache" {
  security_group_id            = aws_security_group.app.id
  description                  = "TLS Valkey/Redis protocol to ElastiCache"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.cache.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_endpoints" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTPS to interface VPC endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_gateway_endpoints" {
  for_each = {
    s3       = aws_vpc_endpoint.s3.prefix_list_id
    dynamodb = aws_vpc_endpoint.dynamodb.prefix_list_id
  }

  security_group_id = aws_security_group.app.id
  description       = "HTTPS to ${each.key} gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = each.value
}

resource "aws_vpc_security_group_egress_rule" "app_allowlisted" {
  for_each = var.enable_nat_gateway ? toset(var.nat_egress_cidrs) : toset([])

  security_group_id = aws_security_group.app.id
  description       = "Allow-listed partner egress ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# ------------------------------------------------------------- isolated tier
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from app tier only"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_app" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Valkey from app tier only"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_ingress_rule" "cache_replication" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Replication between cache nodes"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.cache.id
}

resource "aws_vpc_security_group_egress_rule" "cache_replication" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Replication between cache nodes"
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  referenced_security_group_id = aws_security_group.cache.id
}
