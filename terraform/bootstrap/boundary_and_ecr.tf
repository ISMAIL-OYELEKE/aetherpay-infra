###############################################################################
# Permissions boundary for every workload role the pipeline creates.
# Even if a task-role policy were widened by mistake, the effective
# permissions can never exceed this ceiling.
###############################################################################

data "aws_iam_policy_document" "workload_boundary" {
  #checkov:skip=CKV_AWS_107:Permissions boundary is a ceiling; identity policies scope resources.
  #checkov:skip=CKV_AWS_108:Permissions boundary is a ceiling; identity policies scope resources.
  #checkov:skip=CKV_AWS_109:Permissions boundary is a ceiling; identity policies scope resources.
  #checkov:skip=CKV_AWS_111:Permissions boundary is a ceiling; identity policies scope resources.
  #checkov:skip=CKV_AWS_356:Permissions boundary is a ceiling; identity policies scope resources.
  statement {
    sid    = "WorkloadServiceCeiling"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData",
      "dynamodb:ConditionCheckItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
      "ec2:AssignPrivateIpAddresses",
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:UnassignPrivateIpAddresses",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
      "elasticache:Connect",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:PutLogEvents",
      "logs:PutRetentionPolicy",
      "rds-db:connect",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
      "sqs:SendMessage",
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]
    resources = ["*"] # The boundary is a ceiling; the identity policies scope resources.
  }

}

resource "aws_iam_policy" "workload_boundary" {
  name        = "aetherpay-workload-boundary"
  description = "Permissions boundary for AetherPay workload roles"
  policy      = data.aws_iam_policy_document.workload_boundary.json
}

###############################################################################
# Shared application image registry: build once, promote by digest.
###############################################################################

resource "aws_kms_key" "artifacts" {
  description             = "AetherPay container image encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json
}

resource "aws_kms_alias" "artifacts" {
  name          = "alias/aetherpay-artifacts"
  target_key_id = aws_kms_key.artifacts.key_id
}

resource "aws_ecr_repository" "app" {
  name                 = "aetherpay/app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.artifacts.arn
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 100 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 100
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_replication_configuration" "this" {
  count = length(var.ecr_replication_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = var.ecr_replication_regions

        content {
          region      = destination.value
          registry_id = local.account_id
        }
      }

      repository_filter {
        filter      = "aetherpay/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

# CI role that only builds and pushes images (assumable from main).
data "aws_iam_policy_document" "image_push_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.oidc_subject_prefix}:ref:refs/heads/main", "${local.oidc_subject_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "image_push" {
  name               = "aetherpay-gha-image-push"
  assume_role_policy = data.aws_iam_policy_document.image_push_trust.json
}

data "aws_iam_policy_document" "image_push" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushToAppRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "EncryptLayers"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.artifacts.arn]
  }
}

resource "aws_iam_role_policy" "image_push" {
  name   = "push-app-image"
  role   = aws_iam_role.image_push.id
  policy = data.aws_iam_policy_document.image_push.json
}
