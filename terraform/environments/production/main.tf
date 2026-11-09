###############################################################################
# Production: warm-standby multi-region.
#
#   us-east-1 (primary)    full stack, serves traffic, holds settlement lease
#   us-east-2 (secondary)  full stack at reduced min capacity, Aurora Global
#                          secondary, ledger replica; promoted by ARC flip
#   us-west-2 (witness)    DynamoDB MRSC witness + ARC config home
#
# See docs/ADR-001-Disaster-Recovery.md for the reasoning.
###############################################################################

locals {
  name = "aetherpay-prod"

  default_tags = {
    "aetherpay:environment" = "production"
    "aetherpay:owner"       = "platform"
    "aetherpay:managed-by"  = "terraform"
    "aetherpay:cost-center" = "payments-infra"
  }

  secondary_ecr_repository_arn = replace(var.ecr_repository_arn, ":${var.primary_region}:", ":${var.secondary_region}:")
}

module "ledger" {
  source = "../../modules/ledger"

  providers = {
    aws         = aws
    aws.replica = aws.secondary
  }

  name             = local.name
  replica_region   = var.secondary_region
  witness_region   = var.witness_region
  consistency_mode = "STRONG"
  key_admin_arns   = var.key_admin_arns
}

# Same lookup as modules/data, so the global cluster and its members agree.
data "aws_rds_engine_version" "aurora" {
  engine  = "aurora-postgresql"
  version = "16"
  latest  = true
}

resource "aws_rds_global_cluster" "settlement" {
  global_cluster_identifier = "${local.name}-settlement"
  engine                    = "aurora-postgresql"
  engine_version            = data.aws_rds_engine_version.aurora.version_actual
  storage_encrypted         = true
  deletion_protection       = true
}

module "primary" {
  source = "../../modules/stack"

  name        = "${local.name}-use1"
  region_role = "primary"
  azs         = var.primary_azs
  vpc_cidr    = "10.24.0.0/20"

  domain_name    = "use1.${var.global_domain_name}"
  hosted_zone_id = var.hosted_zone_id

  app_image          = var.app_image_primary
  create_repository  = false
  ecr_repository_arn = var.ecr_repository_arn

  # Signing keys are minted and rotated here, replicated to the secondary.
  secret_replica_regions     = { (var.secondary_region) = module.secondary.secrets_kms_key_arn }
  additional_secret_vpce_ids = [module.secondary.secretsmanager_vpce_id]

  ledger = {
    table_name  = module.ledger.table_name
    table_arn   = module.ledger.table_arn
    kms_key_arn = module.ledger.kms_key_arn
  }

  db = {
    min_acu                   = 2
    max_acu                   = 64
    instance_count            = 3
    global_cluster_identifier = aws_rds_global_cluster.settlement.id
  }

  cache = {
    node_type = "cache.r7g.large"
    replicas  = 3
  }

  ingestor = {
    min_capacity = 6
    max_capacity = 60
  }

  settler = {
    min_capacity = 3
    max_capacity = 80
  }

  alarm_emails             = var.alarm_emails
  key_admin_arns           = var.key_admin_arns
  permissions_boundary_arn = var.permissions_boundary_arn
}

module "secondary" {
  source = "../../modules/stack"

  providers = {
    aws = aws.secondary
  }

  name        = "${local.name}-use2"
  region_role = "secondary"
  azs         = var.secondary_azs
  vpc_cidr    = "10.24.16.0/20" # non-overlapping with primary for future peering/TGW

  domain_name    = "use2.${var.global_domain_name}"
  hosted_zone_id = var.hosted_zone_id

  app_image          = var.app_image_secondary
  create_repository  = false
  ecr_repository_arn = local.secondary_ecr_repository_arn

  create_signing_secrets       = false
  external_signing_secret_arns = module.primary.signing_secret_replica_arns[var.secondary_region]

  ledger = {
    table_name  = module.ledger.table_name
    table_arn   = module.ledger.replica_table_arn
    kms_key_arn = module.ledger.replica_kms_key_arn
  }

  db = {
    min_acu        = 2
    max_acu        = 64
    instance_count = 2
    # Output of the primary that resolves only after the primary writer exists,
    # so the secondary cluster attaches in the right order without depends_on.
    global_cluster_identifier = module.primary.db_global_cluster_identifier
    is_secondary_region       = true
  }

  cache = {
    node_type = "cache.r7g.large"
    replicas  = 2
  }

  # Warm standby: enough to absorb traffic immediately, autoscaling does the rest.
  ingestor = {
    min_capacity = 3
    max_capacity = 60
  }

  settler = {
    min_capacity = 1
    max_capacity = 80
  }

  alarm_emails             = var.alarm_emails
  key_admin_arns           = var.key_admin_arns
  permissions_boundary_arn = var.permissions_boundary_arn
}

module "dr_routing" {
  source = "../../modules/dr-routing"

  providers = {
    aws = aws.arc
  }

  name           = local.name
  hosted_zone_id = var.hosted_zone_id
  domain_name    = var.global_domain_name

  regions = {
    primary = {
      region       = var.primary_region
      alb_dns_name = module.primary.alb_dns_name
      alb_zone_id  = module.primary.alb_zone_id
    }
    secondary = {
      region       = var.secondary_region
      alb_dns_name = module.secondary.alb_dns_name
      alb_zone_id  = module.secondary.alb_zone_id
    }
  }
}
