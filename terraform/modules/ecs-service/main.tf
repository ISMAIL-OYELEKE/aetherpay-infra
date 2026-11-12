###############################################################################
# Reusable hardened Fargate service.
###############################################################################

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region       = data.aws_region.current.region
  tags         = merge(var.tags, { "aetherpay:module" = "ecs-service", "aetherpay:service" = var.name })
  has_listener = var.container_port != null
  container    = "app"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aetherpay/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

# --------------------------------------------------------- execution role
# Used by the ECS agent only: pull the image, write logs. It holds no secret
# permissions because the application reads secrets itself at runtime.
data "aws_iam_policy_document" "execution_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${var.name}-exec"
  assume_role_policy   = data.aws_iam_policy_document.execution_trust.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.tags
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuthToken" # GetAuthorizationToken has no resource-level scoping.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "PullFromOwnRepository"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [var.ecr_repository_arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-and-log"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# --------------------------------------------------------- task definition
resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = var.task_role_arn
  enable_fault_injection   = false

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    merge(
      {
        name                   = local.container
        image                  = var.image
        essential              = true
        user                   = "10001:10001"
        readonlyRootFilesystem = true
        privileged             = false
        stopTimeout            = 30

        # Written the way ECS stores them, so a no-op plan stays empty
        # instead of re-registering the task definition every run.
        systemControls = []
        volumesFrom    = []

        environment = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]

        linuxParameters = {
          initProcessEnabled = true
          capabilities       = { add = [], drop = ["ALL"] }
        }

        mountPoints = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.this.name
            awslogs-region        = local.region
            awslogs-stream-prefix = "app"
            mode                  = "non-blocking"
            max-buffer-size       = "25m"
          }
        }
      },
      # jsondecode(jsonencode()) keeps both branches type-compatible.
      jsondecode(var.command == null ? "{}" : jsonencode({ command = var.command })),
      jsondecode(!local.has_listener ? "{}" : jsonencode({
        portMappings = [{ containerPort = var.container_port, hostPort = var.container_port, protocol = "tcp" }]
        healthCheck = {
          command     = ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}${var.health_check_path}', timeout=3).status == 200 else 1)"]
          interval    = 15
          timeout     = 5
          retries     = 3
          startPeriod = 30
        }
      }))
    )
  ])

  volume {
    name                = "tmp"
    configure_at_launch = false
  }

  tags = local.tags
}

# ----------------------------------------------------------------- service
resource "aws_ecs_service" "this" {
  name             = var.name
  cluster          = var.cluster_arn
  task_definition  = aws_ecs_task_definition.this.arn
  desired_count    = var.min_capacity
  launch_type      = "FARGATE"
  platform_version = "LATEST"

  propagate_tags                    = "SERVICE"
  enable_ecs_managed_tags           = true
  enable_execute_command            = false
  health_check_grace_period_seconds = local.has_listener ? 60 : null
  availability_zone_rebalancing     = "ENABLED"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]

    content {
      target_group_arn = load_balancer.value
      container_name   = local.container
      container_port   = var.container_port
    }
  }

  tags = local.tags

  lifecycle {
    # Application Auto Scaling owns the live task count after creation.
    ignore_changes = [desired_count]
  }
}
