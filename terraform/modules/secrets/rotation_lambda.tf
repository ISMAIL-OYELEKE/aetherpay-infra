###############################################################################
# Rotation Lambda: runs in the private app tier, may only reach the interface
# endpoints on 443, and is identified by the aetherpay:workload=rotation tag.
###############################################################################

data "archive_file" "rotation" {
  type        = "zip"
  source_file = "${path.module}/lambda/rotate_signing_key.py"
  output_path = "${path.module}/.build/rotate_signing_key.zip"
}

resource "aws_security_group" "rotation" {
  name_prefix = "${var.name}-rotation-"
  description = "Signing-key rotation Lambda: HTTPS to VPC endpoints only"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "${var.name}-rotation" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "rotation_to_endpoints" {
  security_group_id            = aws_security_group.rotation.id
  description                  = "HTTPS to interface endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.endpoint_security_group_id
}

resource "aws_cloudwatch_log_group" "rotation" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = local.tags
}

data "aws_iam_policy_document" "rotation_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "rotation" {
  name_prefix          = "${substr(var.name, 0, 20)}-rotation-"
  assume_role_policy   = data.aws_iam_policy_document.rotation_trust.json
  permissions_boundary = var.permissions_boundary_arn

  tags = merge(local.tags, { "aetherpay:workload" = local.rotation_tag })
}

data "aws_iam_policy_document" "rotation" {
  statement {
    sid = "RotateOnlyOurSigningKeys"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [for s in aws_secretsmanager_secret.signing : s.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.secretsmanager_vpce_id]
    }
  }

  statement {
    sid       = "UseSecretsKeyOnlyViaSecretsManager"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.secrets_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.rotation.arn}:*"]
  }

  statement {
    # ENI management for VPC-attached Lambdas. EC2 does not support
    # resource-level scoping for these Describe/Create calls.
    sid = "VpcNetworkInterfaces"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.region]
    }
  }
}

resource "aws_iam_role_policy" "rotation" {
  name   = "rotate-signing-keys"
  role   = aws_iam_role.rotation.id
  policy = data.aws_iam_policy_document.rotation.json
}

resource "aws_sqs_queue" "rotation_dlq" {
  name                      = "${local.function_name}-dlq"
  sqs_managed_sse_enabled   = true # Holds rotation event metadata only, never key material.
  message_retention_seconds = 1209600
  tags                      = local.tags
}

resource "aws_iam_role_policy" "rotation_dlq" {
  name = "rotation-dlq"
  role = aws_iam_role.rotation.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SendFailedInvocations"
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.rotation_dlq.arn
    }]
  })
}

resource "aws_lambda_function" "rotation" {
  #checkov:skip=CKV_AWS_272:Code is built from this repository and shipped inside the signed, reviewed plan artifact.
  #checkov:skip=CKV_AWS_117:Runs in the VPC (vpc_config below).
  #checkov:skip=CKV_AWS_173:No environment variables are defined.
  function_name                  = local.function_name
  description                    = "Rotates AetherPay HMAC signing keys"
  role                           = aws_iam_role.rotation.arn
  runtime                        = "python3.12"
  handler                        = "rotate_signing_key.handler"
  filename                       = data.archive_file.rotation.output_path
  source_code_hash               = data.archive_file.rotation.output_base64sha256
  timeout                        = 30
  memory_size                    = 256
  reserved_concurrent_executions = 2

  vpc_config {
    subnet_ids         = var.app_subnet_ids
    security_group_ids = [aws_security_group.rotation.id]
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.rotation_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.rotation.name
  }

  tags = merge(local.tags, { "aetherpay:workload" = local.rotation_tag })

  depends_on = [
    aws_iam_role_policy.rotation,
    aws_iam_role_policy.rotation_dlq,
  ]
}

resource "aws_lambda_permission" "secretsmanager" {
  statement_id   = "AllowSecretsManagerInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rotation.function_name
  principal      = "secretsmanager.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}
