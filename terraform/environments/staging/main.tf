###############################################################################
# Staging: one regional stack in us-east-1 plus the multi-region ledger.
# Sized small and with deletion protection off so it can be torn down daily.
###############################################################################

locals {
  name = "aetherpay-staging"

  default_tags = {
    "aetherpay:environment" = "staging"
    "aetherpay:owner"       = "platform"
    "aetherpay:managed-by"  = "terraform"
    "aetherpay:cost-center" = "payments-infra"
  }
}

module "ledger" {
  source = "../../modules/ledger"

  providers = {
    aws         = aws
    aws.replica = aws.replica
  }

  name                = local.name
  replica_region      = var.ledger_replica_region
  witness_region      = var.ledger_witness_region
  consistency_mode    = "STRONG"
  key_admin_arns      = var.key_admin_arns
  deletion_protection = false
}

module "stack" {
  source = "../../modules/stack"

  name        = local.name
  region_role = "primary"
  azs         = var.azs
  vpc_cidr    = "10.24.0.0/20"

  domain_name     = var.domain_name
  hosted_zone_id  = var.hosted_zone_id
  certificate_arn = var.certificate_arn

  app_image          = var.app_image
  create_repository  = false
  ecr_repository_arn = var.ecr_repository_arn

  ledger = {
    table_name  = module.ledger.table_name
    table_arn   = module.ledger.table_arn
    kms_key_arn = module.ledger.kms_key_arn
  }

  ingestor = {
    min_capacity = 2
    max_capacity = 6
  }

  settler = {
    min_capacity            = 1
    max_capacity            = 6
    backlog_per_task_target = 50
  }

  db = {
    min_acu        = 0.5
    max_acu        = 2
    instance_count = 1
  }

  cache = {
    node_type = "cache.t4g.micro"
    replicas  = 2
  }

  deletion_protection      = false
  log_retention_days       = 30
  alarm_emails             = var.alarm_emails
  key_admin_arns           = var.key_admin_arns
  permissions_boundary_arn = var.permissions_boundary_arn
}
