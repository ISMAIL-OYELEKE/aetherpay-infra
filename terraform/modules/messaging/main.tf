###############################################################################
# Ingestion queue + dead-letter queue.
# Verified webhooks are enqueued by the ingestor and drained by the settler.
###############################################################################

variable "name" {
  description = "Name prefix, e.g. aetherpay-staging."
  type        = string
}

variable "data_kms_key_arn" {
  description = "CMK for queue encryption."
  type        = string
}

variable "sqs_vpce_id" {
  description = "SQS interface endpoint ID. Message operations from anywhere else are denied."
  type        = string
}

variable "visibility_timeout_seconds" {
  description = "Must exceed the settler's worst-case processing time."
  type        = number
  default     = 120
}

variable "max_receive_count" {
  description = "Deliveries before a message is moved to the DLQ."
  type        = number
  default     = 5
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

locals {
  tags = merge(var.tags, { "aetherpay:module" = "messaging" })
  message_actions = [
    "sqs:SendMessage",
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:ChangeMessageVisibility",
  ]
}

resource "aws_sqs_queue" "dlq" {
  name                              = "${var.name}-ingestion-dlq"
  kms_master_key_id                 = var.data_kms_key_arn
  kms_data_key_reuse_period_seconds = 300
  message_retention_seconds         = 1209600 # 14 days to investigate and redrive.
  tags                              = local.tags
}

resource "aws_sqs_queue" "ingestion" {
  name                              = "${var.name}-ingestion"
  kms_master_key_id                 = var.data_kms_key_arn
  kms_data_key_reuse_period_seconds = 300
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  message_retention_seconds         = 345600 # 4 days
  receive_wait_time_seconds         = 20     # long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = local.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.ingestion.arn]
  })
}

data "aws_iam_policy_document" "queue" {
  for_each = {
    ingestion = aws_sqs_queue.ingestion.arn
    dlq       = aws_sqs_queue.dlq.arn
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [each.value]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyMessageOpsOutsideVpcEndpoint"
    effect    = "Deny"
    actions   = local.message_actions
    resources = [each.value]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceVpce"
      values   = [var.sqs_vpce_id]
    }
  }
}

resource "aws_sqs_queue_policy" "this" {
  for_each = {
    ingestion = aws_sqs_queue.ingestion.id
    dlq       = aws_sqs_queue.dlq.id
  }

  queue_url = each.value
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

output "ingestion_queue_arn" {
  description = "Ingestion queue ARN."
  value       = aws_sqs_queue.ingestion.arn
}

output "ingestion_queue_url" {
  description = "Ingestion queue URL."
  value       = aws_sqs_queue.ingestion.id
}

output "ingestion_queue_name" {
  description = "Ingestion queue name (CloudWatch dimension)."
  value       = aws_sqs_queue.ingestion.name
}

output "dlq_arn" {
  description = "Dead-letter queue ARN."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Dead-letter queue name (CloudWatch dimension)."
  value       = aws_sqs_queue.dlq.name
}
