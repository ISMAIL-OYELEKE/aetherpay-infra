###############################################################################
# ECS cluster + private image registry.
###############################################################################

variable "name" {
  description = "Name prefix, e.g. aetherpay-staging."
  type        = string
}

variable "data_kms_key_arn" {
  description = "CMK for ECR image encryption."
  type        = string
}

variable "create_repository" {
  description = "Create the ECR repository (false in a secondary region that uses replication)."
  type        = bool
  default     = true
}

variable "replication_regions" {
  description = "Regions to replicate images to (DR)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

locals {
  tags = merge(var.tags, { "aetherpay:module" = "compute" })
}

data "aws_caller_identity" "current" {}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enhanced" # emits RunningTaskCount used by queue-backlog scaling
  }

  tags = local.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

resource "aws_ecr_repository" "app" {
  count = var.create_repository ? 1 : 0

  name                 = "${var.name}/app"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.data_kms_key_arn
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  count = var.create_repository ? 1 : 0

  repository = aws_ecr_repository.app[0].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 50 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 50
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_replication_configuration" "this" {
  count = var.create_repository && length(var.replication_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = var.replication_regions

        content {
          region      = destination.value
          registry_id = data.aws_caller_identity.current.account_id
        }
      }

      repository_filter {
        filter      = "${var.name}/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "repository_url" {
  description = "ECR repository URL."
  value       = try(aws_ecr_repository.app[0].repository_url, null)
}

output "repository_arn" {
  description = "ECR repository ARN."
  value       = try(aws_ecr_repository.app[0].arn, null)
}
