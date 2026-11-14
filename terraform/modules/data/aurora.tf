###############################################################################
# Aurora PostgreSQL (Serverless v2): the settlement batch workspace.
#
# Credentials: the master password is generated, stored and rotated by RDS in
# Secrets Manager under the secrets CMK (manage_master_user_password). It is
# break-glass only. Workloads connect with IAM database authentication, so no
# application password exists anywhere.
###############################################################################

locals {
  tags = merge(var.tags, { "aetherpay:module" = "data" })
}

data "aws_caller_identity" "current" {}

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-isolated"
  description = "Isolated tier subnets for Aurora"
  subnet_ids  = var.isolated_subnet_ids
  tags        = local.tags
}

resource "aws_rds_cluster_parameter_group" "this" {
  name_prefix = "${var.name}-apg16-"
  family      = "aurora-postgresql16"
  description = "AetherPay hardened Aurora PostgreSQL parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "ssl_min_protocol_version"
    value = "TLSv1.3"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl" # schema changes only; never log statements carrying payment data
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "password_encryption"
    value = "scram-sha-256"
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_iam_policy_document" "monitoring_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "monitoring" {
  name_prefix          = "${substr(var.name, 0, 20)}-rdsmon-"
  assume_role_policy   = data.aws_iam_policy_document.monitoring_trust.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# AWS retires Aurora minor versions; a hard-coded minor (it was 16.6) stops
# being creatable. Resolve the newest minor of the requested major instead.
data "aws_rds_engine_version" "aurora" {
  engine  = "aurora-postgresql"
  version = var.db_engine_version
  latest  = true
}

# ------------------------------------------------- master credential
# RDS-managed master passwords (manage_master_user_password) are not supported
# for Aurora Global Database clusters. A global primary therefore gets its own
# Secrets Manager secret under the secrets CMK instead:
#   * the password is generated at apply time (ephemeral) and sent to RDS and
#     Secrets Manager through write-only arguments, so it never enters state;
#   * it is rotated by bumping var.db_master_password_version, which sends a
#     new value to both in the same apply;
#   * it is replicated to the secondary region so break-glass works after a
#     regional failover. Workloads never use it: they use IAM database auth.
# A standalone cluster (staging) keeps the RDS-managed secret.
locals {
  is_global_primary = var.is_global_member && !var.is_secondary_region
  is_standalone     = !var.is_global_member
}

ephemeral "random_password" "db_master" {
  count = local.is_global_primary ? 1 : 0

  length           = 40
  override_special = "!#$%^&*()-_=+[]{}<>:?" # RDS rejects / @ " and space
}

resource "aws_secretsmanager_secret" "db_master" {
  #checkov:skip=CKV2_AWS_57:Managed rotation is unavailable for Aurora Global master users; rotated by bumping db_master_password_version (write-only, never in state).
  count = local.is_global_primary ? 1 : 0

  name        = "${var.name}-db-master"
  description = "Aurora Global master credential (break-glass only; workloads use IAM auth)."
  kms_key_id  = var.secrets_kms_key_arn

  dynamic "replica" {
    for_each = var.db_secret_replica_regions
    content {
      region     = replica.key
      kms_key_id = replica.value
    }
  }

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  count = local.is_global_primary ? 1 : 0

  secret_id = aws_secretsmanager_secret.db_master[0].id
  secret_string_wo = jsonencode({
    username = "aetherpay_admin"
    password = ephemeral.random_password.db_master[0].result
  })
  secret_string_wo_version = var.db_master_password_version
}

resource "aws_rds_cluster" "this" {
  #checkov:skip=CKV2_AWS_8:Continuous backups with 35-day PITR plus Aurora Global replication; AWS Backup is layered on at the account level.
  cluster_identifier        = "${var.name}-settlement"
  engine                    = "aurora-postgresql"
  engine_mode               = "provisioned"
  engine_version            = data.aws_rds_engine_version.aurora.version_actual
  global_cluster_identifier = var.global_cluster_identifier

  database_name                       = var.is_secondary_region ? null : var.db_name
  master_username                     = var.is_secondary_region ? null : "aetherpay_admin"
  manage_master_user_password         = local.is_standalone ? true : null
  master_user_secret_kms_key_id       = local.is_standalone ? var.secrets_kms_key_arn : null
  master_password_wo                  = local.is_global_primary ? ephemeral.random_password.db_master[0].result : null
  master_password_wo_version          = local.is_global_primary ? var.db_master_password_version : null
  iam_database_authentication_enabled = true

  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [var.db_security_group_id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  port                            = 5432
  network_type                    = "IPV4"

  storage_encrypted = true
  kms_key_id        = var.data_kms_key_arn

  backup_retention_period         = var.db_backup_retention_days
  preferred_backup_window         = "03:00-04:00"
  preferred_maintenance_window    = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot           = true
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = false
  final_snapshot_identifier       = "${var.name}-settlement-final"
  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true

  serverlessv2_scaling_configuration {
    min_capacity = var.db_min_acu
    max_capacity = var.db_max_acu
  }

  tags = local.tags

  lifecycle {
    # A global secondary inherits these from the primary; ignore to avoid drift.
    ignore_changes = [replication_source_identifier, global_cluster_identifier]
  }
}

resource "aws_rds_cluster_instance" "this" {
  count = var.db_instance_count

  identifier                            = "${var.name}-settlement-${count.index}"
  cluster_identifier                    = aws_rds_cluster.this.id
  engine                                = aws_rds_cluster.this.engine
  engine_version                        = aws_rds_cluster.this.engine_version
  instance_class                        = "db.serverless"
  db_subnet_group_name                  = aws_db_subnet_group.this.name
  publicly_accessible                   = false
  auto_minor_version_upgrade            = true
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = var.data_kms_key_arn
  performance_insights_retention_period = 7
  copy_tags_to_snapshot                 = true

  tags = local.tags
}
