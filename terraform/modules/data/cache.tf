###############################################################################
# ElastiCache (Valkey, Redis OSS compatible): webhook de-duplication and
# short-lived session state. TLS required, CMK at rest, IAM authentication.
# The default user is disabled, so the cache has no shared password.
###############################################################################

locals {
  cache_user = coalesce(var.cache_iam_user_name, "${var.name}-ingestor")
}

resource "aws_elasticache_subnet_group" "this" {
  name        = "${var.name}-cache"
  description = "Isolated tier subnets for ElastiCache"
  subnet_ids  = var.isolated_subnet_ids
  tags        = local.tags
}

# Valkey requires a "default" user in every user group; this one is locked out.
resource "aws_elasticache_user" "default_disabled" {
  user_id       = "${replace(var.name, "_", "-")}-default-off"
  user_name     = "default"
  engine        = "valkey"
  access_string = "off -@all"

  authentication_mode {
    type = "no-password-required"
  }

  tags = local.tags
}

resource "aws_elasticache_user" "workload" {
  # For IAM auth the user_id must equal the user_name.
  user_id       = local.cache_user
  user_name     = local.cache_user
  engine        = "valkey"
  access_string = "on ~dedup:* ~session:* -@all +@read +@write +@keyspace +@connection -@dangerous"

  authentication_mode {
    type = "iam"
  }

  tags = local.tags
}

resource "aws_elasticache_user_group" "this" {
  user_group_id = "${var.name}-users"
  engine        = "valkey"
  user_ids = [
    aws_elasticache_user.default_disabled.user_id,
    aws_elasticache_user.workload.user_id,
  ]

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "cache" {
  name              = "/aetherpay/${var.name}/elasticache"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

resource "aws_elasticache_replication_group" "this" {
  #checkov:skip=CKV2_AWS_50:Multi-AZ failover is enabled whenever cache_replicas > 1 (all environments use >= 2).
  replication_group_id = "${var.name}-cache"
  description          = "AetherPay dedup and session cache"
  engine               = "valkey"
  engine_version       = var.cache_engine_version
  node_type            = var.cache_node_type
  port                 = 6379

  num_cache_clusters         = var.cache_replicas
  automatic_failover_enabled = var.cache_replicas > 1
  multi_az_enabled           = var.cache_replicas > 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [var.cache_security_group_id]
  user_group_ids     = [aws_elasticache_user_group.this.user_group_id]

  at_rest_encryption_enabled = true
  kms_key_id                 = var.data_kms_key_arn
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"

  snapshot_retention_limit   = 7
  snapshot_window            = "02:00-03:00"
  maintenance_window         = "sun:05:30-sun:06:30"
  auto_minor_version_upgrade = true
  apply_immediately          = false

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.cache.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
  }

  tags = local.tags
}
