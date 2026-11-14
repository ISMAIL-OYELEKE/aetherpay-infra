###############################################################################
# Regional AetherPay stack: composes every building-block module.
# Staging uses one instance; production uses one per region.
#
# Dependency order is explicit through resource attributes, never constructed
# strings: e.g. the services receive the cache endpoint from
# module.data.cache_primary_endpoint, so Terraform cannot create the ECS
# services before ElastiCache is available (the root cause of Snippet B's
# crash loop). No depends_on is needed because the data flow is the graph.
###############################################################################

locals {
  tags = merge(var.tags, { "aetherpay:stack" = var.name, "aetherpay:region-role" = var.region_role })

  app_port          = 8080
  metrics_namespace = "AetherPay/${var.name}"

  ecr_repository_arn = coalesce(var.ecr_repository_arn, module.compute.repository_arn)

  # Signing secrets are created (and rotated) in the primary region and
  # replicated to secondaries, so partners sign with one key everywhere.
  signing_secret_arns = var.create_signing_secrets ? module.secrets[0].signing_secret_arns : var.external_signing_secret_arns
}


module "security" {
  source = "../security"

  name           = var.name
  key_admin_arns = var.key_admin_arns
  tags           = local.tags
}

module "networking" {
  source = "../networking"

  name                     = var.name
  vpc_cidr                 = var.vpc_cidr
  azs                      = var.azs
  app_port                 = local.app_port
  ingress_cidrs            = var.ingress_cidrs
  enable_nat_gateway       = var.enable_nat_gateway
  nat_egress_cidrs         = var.nat_egress_cidrs
  logs_kms_key_arn         = module.security.logs_kms_key_arn
  flow_log_retention_days  = var.log_retention_days
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

module "secrets" {
  source = "../secrets"
  count  = var.create_signing_secrets ? 1 : 0

  name                       = var.name
  secrets_kms_key_arn        = module.security.secrets_kms_key_arn
  logs_kms_key_arn           = module.security.logs_kms_key_arn
  vpc_id                     = module.networking.vpc_id
  app_subnet_ids             = module.networking.app_subnet_ids
  endpoint_security_group_id = module.networking.endpoint_security_group_id
  secretsmanager_vpce_id     = module.networking.interface_endpoint_ids["secretsmanager"]
  additional_vpce_ids        = var.additional_secret_vpce_ids
  replica_regions            = var.secret_replica_regions
  reader_workloads           = ["ingestor", "settler"]
  permissions_boundary_arn   = var.permissions_boundary_arn
  log_retention_days         = var.log_retention_days
  tags                       = local.tags
}

module "messaging" {
  source = "../messaging"

  name             = var.name
  data_kms_key_arn = module.security.data_kms_key_arn
  sqs_vpce_id      = module.networking.interface_endpoint_ids["sqs"]
  tags             = local.tags
}

module "data" {
  source = "../data"

  name                      = var.name
  isolated_subnet_ids       = module.networking.isolated_subnet_ids
  db_security_group_id      = module.networking.security_group_ids["db"]
  cache_security_group_id   = module.networking.security_group_ids["cache"]
  data_kms_key_arn          = module.security.data_kms_key_arn
  secrets_kms_key_arn       = module.security.secrets_kms_key_arn
  logs_kms_key_arn          = module.security.logs_kms_key_arn
  db_min_acu                = var.db.min_acu
  db_max_acu                = var.db.max_acu
  db_instance_count         = var.db.instance_count
  global_cluster_identifier = var.db.global_cluster_identifier
  is_secondary_region       = var.db.is_secondary_region
  is_global_member          = var.db.is_global_member
  db_secret_replica_regions = var.secret_replica_regions
  cache_node_type           = var.cache.node_type
  cache_replicas            = var.cache.replicas
  deletion_protection       = var.deletion_protection
  log_retention_days        = var.log_retention_days
  permissions_boundary_arn  = var.permissions_boundary_arn
  tags                      = local.tags
}

module "workload_iam" {
  source = "../workload-iam"

  name                     = var.name
  permissions_boundary_arn = var.permissions_boundary_arn

  vpce_ids = {
    secretsmanager = module.networking.interface_endpoint_ids["secretsmanager"]
    sqs            = module.networking.interface_endpoint_ids["sqs"]
    dynamodb       = module.networking.dynamodb_gateway_endpoint_id
  }

  secrets_kms_key_arn         = module.security.secrets_kms_key_arn
  data_kms_key_arn            = module.security.data_kms_key_arn
  ledger_kms_key_arn          = var.ledger.kms_key_arn
  partner_hmac_secret_arn     = local.signing_secret_arns["partner-webhook-hmac"]
  custodian_signer_secret_arn = local.signing_secret_arns["custodian-request-signer"]
  ingestion_queue_arn         = module.messaging.ingestion_queue_arn
  ledger_table_arn            = var.ledger.table_arn
  cache_replication_group_arn = module.data.cache_replication_group_arn
  cache_user_arn              = module.data.cache_user_arn
  db_cluster_resource_id      = module.data.db_cluster_resource_id
  tags                        = local.tags
}

module "compute" {
  source = "../compute"

  name                = var.name
  data_kms_key_arn    = module.security.data_kms_key_arn
  create_repository   = var.create_repository
  replication_regions = var.ecr_replication_regions
  tags                = local.tags
}

module "edge" {
  source = "../edge"

  name                  = var.name
  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  alb_security_group_id = module.networking.security_group_ids["alb"]
  app_port              = local.app_port
  waf_web_acl_arn       = module.security.waf_web_acl_arn
  domain_name           = var.domain_name
  hosted_zone_id        = var.hosted_zone_id
  certificate_arn       = var.certificate_arn

  subject_alternative_names     = var.certificate_sans
  create_san_validation_records = var.create_san_validation_records
  deletion_protection           = var.deletion_protection
  tags                          = local.tags
}

# ----------------------------------------------------------------- alarms
resource "aws_sns_topic" "alarms" {
  name              = "${var.name}-alarms"
  kms_master_key_id = module.security.data_kms_key_arn # key policy grants CloudWatch publish rights
  tags              = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name}-ingestion-dlq-not-empty"
  alarm_description   = "Poison or failed settlement messages are in the DLQ. Investigate before redriving; never auto-scale on DLQ depth."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = module.messaging.dlq_name }
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-target-5xx"
  alarm_description   = "Webhook targets returning 5xx; partners will retry and may suspend us."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = module.edge.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.alarms.arn]
  tags                = local.tags
}

# --------------------------------------------------------------- services
locals {
  common_environment = {
    AETHERPAY_ENV          = var.name
    AETHERPAY_REGION_ROLE  = var.region_role
    METRICS_NAMESPACE      = local.metrics_namespace
    QUEUE_URL              = module.messaging.ingestion_queue_url
    LEDGER_TABLE           = var.ledger.table_name
    CACHE_HOST             = module.data.cache_primary_endpoint
    CACHE_PORT             = "6379"
    CACHE_USER             = module.data.cache_user_name
    CACHE_REPLICATION_ID   = module.data.cache_replication_group_id
    PARTNER_HMAC_KEY_ARN   = local.signing_secret_arns["partner-webhook-hmac"]
    CUSTODIAN_SIGNER_ARN   = local.signing_secret_arns["custodian-request-signer"]
    DB_HOST                = module.data.db_endpoint
    DB_NAME                = module.data.db_name
    DB_USER                = "settler"
    OTEL_SERVICE_NAMESPACE = "aetherpay"
  }
}

module "ingestor" {
  source = "../ecs-service"

  name               = "${var.name}-ingestor"
  cluster_arn        = module.compute.cluster_arn
  cluster_name       = module.compute.cluster_name
  image              = var.app_image
  cpu                = var.ingestor.cpu
  memory             = var.ingestor.memory
  container_port     = local.app_port
  task_role_arn      = module.workload_iam.ingestor_task_role_arn
  subnet_ids         = module.networking.app_subnet_ids
  security_group_ids = [module.networking.security_group_ids["app"]]
  target_group_arn   = module.edge.target_group_arn
  ecr_repository_arn = local.ecr_repository_arn
  logs_kms_key_arn   = module.security.logs_kms_key_arn
  log_retention_days = var.log_retention_days
  environment        = merge(local.common_environment, { AETHERPAY_COMPONENT = "ingestor", PORT = tostring(local.app_port) })
  min_capacity       = var.ingestor.min_capacity
  max_capacity       = var.ingestor.max_capacity

  alb_request_scaling = {
    resource_label      = module.edge.request_count_resource_label
    requests_per_target = var.ingestor.requests_per_target
  }

  alarm_topic_arn          = aws_sns_topic.alarms.arn
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}

module "settler" {
  source = "../ecs-service"

  name               = "${var.name}-settler"
  cluster_arn        = module.compute.cluster_arn
  cluster_name       = module.compute.cluster_name
  image              = var.app_image
  command            = ["python", "-m", "aetherpay.settler"]
  cpu                = var.settler.cpu
  memory             = var.settler.memory
  task_role_arn      = module.workload_iam.settler_task_role_arn
  subnet_ids         = module.networking.app_subnet_ids
  security_group_ids = [module.networking.security_group_ids["app"]]
  ecr_repository_arn = local.ecr_repository_arn
  logs_kms_key_arn   = module.security.logs_kms_key_arn
  log_retention_days = var.log_retention_days
  environment        = merge(local.common_environment, { AETHERPAY_COMPONENT = "settler" })
  min_capacity       = var.settler.min_capacity
  max_capacity       = var.settler.max_capacity

  queue_scaling = {
    queue_name              = module.messaging.ingestion_queue_name
    backlog_per_task_target = var.settler.backlog_per_task_target
    burst_age_seconds       = var.settler.burst_age_seconds
  }

  scale_out_cooldown_seconds = 60
  scale_in_cooldown_seconds  = 900

  alarm_topic_arn          = aws_sns_topic.alarms.arn
  permissions_boundary_arn = var.permissions_boundary_arn
  tags                     = local.tags
}
