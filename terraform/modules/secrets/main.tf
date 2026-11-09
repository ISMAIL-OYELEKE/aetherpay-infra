###############################################################################
# Signing-key secrets with CMK envelope encryption and automated rotation.
#
# Zero plain text: there is no aws_secretsmanager_secret_version here. The
# first value is minted by the rotation Lambda when rotation is enabled, so
# key material never exists in code, plan files or state.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tags            = merge(var.tags, { "aetherpay:module" = "secrets" })
  rotation_tag    = "rotation"
  allowed_readers = distinct(concat(var.reader_workloads, [local.rotation_tag]))
  function_name   = "${var.name}-rotate-signing-keys"
}

resource "aws_secretsmanager_secret" "signing" {
  for_each = var.signing_keys

  name                    = "${var.name}/signing/${each.key}"
  description             = each.value
  kms_key_id              = var.secrets_kms_key_arn
  recovery_window_in_days = 30

  dynamic "replica" {
    for_each = var.replica_regions

    content {
      region     = replica.key
      kms_key_id = replica.value
    }
  }

  tags = merge(local.tags, { "aetherpay:secret-class" = "signing-key" })
}

###############################################################################
# Resource policy: the secret can only be read or written
#   (a) through this VPC's Secrets Manager endpoint, and
#   (b) by principals tagged with an allowed aetherpay:workload value.
# Terraform itself never needs GetSecretValue, so it is unaffected.
###############################################################################

data "aws_iam_policy_document" "secret" {
  for_each = var.signing_keys

  statement {
    sid    = "DenyValueAccessOutsideVpcEndpoint"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.signing[each.key].arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = concat([var.secretsmanager_vpce_id], var.additional_vpce_ids)
    }
  }

  statement {
    sid       = "DenyValueAccessToUntaggedWorkloads"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.signing[each.key].arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalTag/aetherpay:workload"
      values   = local.allowed_readers
    }
  }
}

resource "aws_secretsmanager_secret_policy" "signing" {
  for_each = var.signing_keys

  secret_arn          = aws_secretsmanager_secret.signing[each.key].arn
  policy              = data.aws_iam_policy_document.secret[each.key].json
  block_public_policy = true
}

resource "aws_secretsmanager_secret_rotation" "signing" {
  for_each = var.signing_keys

  secret_id           = aws_secretsmanager_secret.signing[each.key].id
  rotation_lambda_arn = aws_lambda_function.rotation.arn
  rotate_immediately  = true

  rotation_rules {
    schedule_expression = var.rotation_schedule
  }

  depends_on = [
    aws_lambda_permission.secretsmanager,
    aws_secretsmanager_secret_policy.signing,
  ]
}
