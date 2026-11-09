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

resource "aws_rds_cluster" "this" {
  #checkov:skip=CKV2_AWS_8:Continuous backups with 35-day PITR plus Aurora Global replication; AWS Backup is layered on at the account level.
  cluster_identifier        = "${var.name}-settlement"
  engine                    = "aurora-postgresql"
  engine_mode               = "provisioned"
  engine_version            = var.db_engine_version
  global_cluster_identifier = var.global_cluster_identifier

  database_name                       = var.is_secondary_region ? null : var.db_name
  master_username                     = var.is_secondary_region ? null : "aetherpay_admin"
  manage_master_user_password         = var.is_secondary_region ? null : true
  master_user_secret_kms_key_id       = var.is_secondary_region ? null : var.secrets_kms_key_arn
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
