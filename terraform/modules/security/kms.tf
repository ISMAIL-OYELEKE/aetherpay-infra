###############################################################################
# Customer-managed KMS keys, one per blast radius:
#   secrets - Secrets Manager envelope encryption
#   data    - Aurora, ElastiCache, SQS, ECR
#   logs    - CloudWatch Logs (flow logs, WAF, ECS, Lambda)
#
# Key policies use explicit action lists (no kms:*). In a key policy the
# Resource element can only be "*", which means "this key".
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_root = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
  region       = data.aws_region.current.region
  tags         = merge(var.tags, { "aetherpay:module" = "security" })

  key_admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:CreateAlias",
    "kms:CreateGrant",
    "kms:DeleteAlias",
    "kms:DescribeKey",
    "kms:DisableKey",
    "kms:DisableKeyRotation",
    "kms:EnableKey",
    "kms:EnableKeyRotation",
    "kms:GetKeyPolicy",
    "kms:GetKeyRotationStatus",
    "kms:ListAliases",
    "kms:ListGrants",
    "kms:ListKeyPolicies",
    "kms:ListResourceTags",
    "kms:PutKeyPolicy",
    "kms:RevokeGrant",
    "kms:RotateKeyOnDemand",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:UpdateAlias",
    "kms:UpdateKeyDescription",
  ]

  key_usage_actions = [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:GenerateDataKey",
    "kms:GenerateDataKeyWithoutPlaintext",
    "kms:ReEncryptFrom",
    "kms:ReEncryptTo",
  ]

  keys = {
    secrets = "Secrets Manager envelope encryption for ${var.name}"
    data    = "Aurora, ElastiCache, SQS and ECR encryption for ${var.name}"
    logs    = "CloudWatch Logs encryption for ${var.name}"
  }
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:Key policy; Resource "*" means this key only.
  #checkov:skip=CKV_AWS_111:Key policy; Resource "*" means this key only.
  #checkov:skip=CKV_AWS_356:Key policy; Resource "*" means this key only.
  for_each = local.keys

  # Account root keeps the ability to delegate via IAM, so the key can never be
  # orphaned; every individual permission is still granted by a scoped IAM policy.
  statement {
    sid       = "AccountRootDelegatesToIam"
    effect    = "Allow"
    actions   = distinct(concat(local.key_admin_actions, local.key_usage_actions))
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  dynamic "statement" {
    for_each = length(var.key_admin_arns) > 0 ? [1] : []

    content {
      sid       = "KeyAdministratorsManageButCannotUse"
      effect    = "Allow"
      actions   = local.key_admin_actions
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_admin_arns
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []

    content {
      sid    = "CloudWatchLogsInThisAccount"
      effect = "Allow"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${local.region}.amazonaws.com"]
      }

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:${data.aws_partition.current.partition}:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "data" ? [1] : []

    content {
      sid       = "CloudWatchAlarmsPublishToEncryptedSns"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["cloudwatch.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "secrets" ? [1] : []

    content {
      sid       = "DenyUseOutsideSecretsManager"
      effect    = "Deny"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${local.region}.amazonaws.com"]
      }

      # Allow the account root itself so a break-glass recovery is still possible.
      condition {
        test     = "StringNotEquals"
        variable = "aws:PrincipalArn"
        values   = [local.account_root]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  for_each = local.keys

  description             = each.value
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = var.key_deletion_window_days
  policy                  = data.aws_iam_policy_document.key[each.key].json

  tags = merge(local.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_kms_alias" "this" {
  for_each = local.keys

  name          = "alias/${var.name}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}
