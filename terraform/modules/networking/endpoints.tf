###############################################################################
# VPC endpoints. Interface endpoints live in the ISOLATED tier so that the
# app tier reaches AWS APIs over PrivateLink on 443 only, and the isolated tier
# is reachable exclusively from the app tier on strict ports.
###############################################################################

data "aws_caller_identity" "current" {}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.name}-vpce-"
  description = "Interface VPC endpoints: HTTPS from the application tier only"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https_from_app" {
  for_each = toset(local.app_cidrs)

  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from app subnet ${each.value}"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

# Endpoints only answer; no egress rule is required (security groups are stateful).

locals {
  # Endpoint policies are a perimeter: only this account's principals, and
  # only the API calls the workloads make. IAM policies scope the resources.
  endpoint_actions = {
    "ecr.api"      = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    "ecr.dkr"      = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    logs           = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    monitoring     = ["cloudwatch:PutMetricData"]
    secretsmanager = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"]
    kms            = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    sqs            = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
    sts            = ["sts:GetCallerIdentity"]
    xray           = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
  }
}

data "aws_iam_policy_document" "interface_endpoint" {
  for_each = toset(var.interface_endpoints)

  statement {
    sid       = "OnlyThisAccountsPrincipals"
    effect    = "Allow"
    actions   = lookup(local.endpoint_actions, each.key, ["${split(".", each.key)[0]}:Get*", "${split(".", each.key)[0]}:Describe*"])
    resources = ["*"] #checkov:skip=CKV_AWS_356:Endpoint policy is a network perimeter; resources are scoped by identity policies.

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.isolated[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  policy              = data.aws_iam_policy_document.interface_endpoint[each.key].json

  tags = merge(local.tags, { Name = "${var.name}-vpce-${replace(each.value, ".", "-")}" })
}

###############################################################################
# Gateway endpoints (free) for S3 and DynamoDB, attached to app route tables.
###############################################################################

data "aws_iam_policy_document" "s3_gateway" {
  statement {
    sid       = "OwnAccountBuckets"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "EcrImageLayers"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  policy            = data.aws_iam_policy_document.s3_gateway.json

  tags = merge(local.tags, { Name = "${var.name}-vpce-s3" })
}

data "aws_iam_policy_document" "dynamodb_gateway" {
  statement {
    sid       = "OwnAccountTables"
    effect    = "Allow"
    actions   = ["dynamodb:*"]
    resources = ["arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  policy            = data.aws_iam_policy_document.dynamodb_gateway.json

  tags = merge(local.tags, { Name = "${var.name}-vpce-dynamodb" })
}
