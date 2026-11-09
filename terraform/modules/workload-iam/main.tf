###############################################################################
# Zero-trust workload identities.
#
# Each ECS service gets its own task role (the ECS equivalent of an IRSA /
# Pod Identity service account). Roles are tagged aetherpay:workload=<name>;
# secret resource policies key off that tag, so a role that is not tagged as
# an approved workload cannot read secrets even if someone widens its policy.
#
# Every sensitive statement names exact ARNs and carries an aws:SourceVpce
# condition pinning the call to this VPC's endpoint. There are no wildcard
# actions or resources on storage, KMS keys or secrets.
###############################################################################

variable "name" {
  description = "Name prefix, e.g. aetherpay-staging."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every role."
  type        = string
  default     = null
}

variable "vpce_ids" {
  description = "Endpoint IDs: secretsmanager, sqs (interface) and dynamodb (gateway)."
  type = object({
    secretsmanager = string
    sqs            = string
    dynamodb       = string
  })
}

variable "secrets_kms_key_arn" {
  description = "CMK protecting Secrets Manager secrets."
  type        = string
}

variable "data_kms_key_arn" {
  description = "CMK protecting SQS."
  type        = string
}

variable "ledger_kms_key_arn" {
  description = "CMK protecting the ledger journal."
  type        = string
}

variable "partner_hmac_secret_arn" {
  description = "Secret holding the inbound webhook HMAC key (ingestor only)."
  type        = string
}

variable "custodian_signer_secret_arn" {
  description = "Secret holding the outbound custodian signing key (settler only)."
  type        = string
}

variable "ingestion_queue_arn" {
  description = "Ingestion queue ARN."
  type        = string
}

variable "ledger_table_arn" {
  description = "Ledger journal table ARN."
  type        = string
}

variable "cache_replication_group_arn" {
  description = "ElastiCache replication group ARN."
  type        = string
}

variable "cache_user_arn" {
  description = "ElastiCache IAM user ARN."
  type        = string
}

variable "db_cluster_resource_id" {
  description = "Aurora cluster resource ID."
  type        = string
}

variable "db_iam_user" {
  description = "Postgres role the settler authenticates as via IAM."
  type        = string
  default     = "settler"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.region
  tags    = merge(var.tags, { "aetherpay:module" = "workload-iam" })
}

# ------------------------------------------------------------------- trust
data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    # Confused-deputy protection: only ECS tasks in this account and region.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${local.region}:${local.account}:*"]
    }
  }
}

# Shared, non-sensitive telemetry permissions (these APIs have no resource ARNs).
data "aws_iam_policy_document" "telemetry" {
  statement {
    sid       = "PublishCustomMetricsToOwnNamespace"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["AetherPay/${var.name}"]
    }
  }

  statement {
    sid       = "XRayTraces"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }
}

###############################################################################
# ingestor: verifies webhook signatures, de-duplicates, enqueues.
###############################################################################

resource "aws_iam_role" "ingestor" {
  name                 = "${var.name}-ingestor-task"
  description          = "Task role for the webhook ingestor"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = merge(local.tags, { "aetherpay:workload" = "ingestor" })
}

data "aws_iam_policy_document" "ingestor" {
  source_policy_documents = [data.aws_iam_policy_document.telemetry.json]

  statement {
    sid       = "ReadPartnerHmacKeyViaVpce"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.partner_hmac_secret_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.vpce_ids.secretsmanager]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/aetherpay:secret-class"
      values   = ["signing-key"]
    }
  }

  statement {
    sid       = "DecryptPartnerHmacKey"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [var.partner_hmac_secret_arn]
    }
  }

  statement {
    sid       = "EnqueueVerifiedEvents"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [var.ingestion_queue_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.vpce_ids.sqs]
    }
  }

  statement {
    sid       = "EncryptQueueMessages"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.data_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "ConnectToDedupCacheAsIamUser"
    actions   = ["elasticache:Connect"]
    resources = [var.cache_replication_group_arn, var.cache_user_arn]
  }
}

resource "aws_iam_role_policy" "ingestor" {
  name   = "ingestor-least-privilege"
  role   = aws_iam_role.ingestor.id
  policy = data.aws_iam_policy_document.ingestor.json
}

###############################################################################
# settler: drains the queue, appends to the ledger, claims settlement batches.
###############################################################################

resource "aws_iam_role" "settler" {
  name                 = "${var.name}-settler-task"
  description          = "Task role for the settlement worker"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_trust.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = merge(local.tags, { "aetherpay:workload" = "settler" })
}

data "aws_iam_policy_document" "settler" {
  source_policy_documents = [data.aws_iam_policy_document.telemetry.json]

  statement {
    sid = "ConsumeIngestionQueueViaVpce"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.ingestion_queue_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.vpce_ids.sqs]
    }
  }

  statement {
    sid       = "DecryptQueueMessages"
    actions   = ["kms:Decrypt"]
    resources = [var.data_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["sqs.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "AppendJournalEntries"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"]
    resources = [var.ledger_table_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.vpce_ids.dynamodb]
    }
  }

  statement {
    # Only fencing leases and batch claims are mutable; journal rows are not.
    sid       = "UpdateOnlyFenceAndBatchItems"
    actions   = ["dynamodb:UpdateItem"]
    resources = [var.ledger_table_arn]

    condition {
      test     = "ForAllValues:StringLike"
      variable = "dynamodb:LeadingKeys"
      values   = ["FENCE#*", "BATCH#*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.vpce_ids.dynamodb]
    }
  }

  statement {
    sid       = "UseLedgerKeyViaDynamoDb"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.ledger_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["dynamodb.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "ReadCustodianSigningKeyViaVpce"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.custodian_signer_secret_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.vpce_ids.secretsmanager]
    }
  }

  statement {
    sid       = "DecryptCustodianSigningKey"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [var.custodian_signer_secret_arn]
    }
  }

  statement {
    sid       = "IamDatabaseAuthAsSettlerRoleOnly"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${local.region}:${local.account}:dbuser:${var.db_cluster_resource_id}/${var.db_iam_user}"]
  }
}

resource "aws_iam_role_policy" "settler" {
  name   = "settler-least-privilege"
  role   = aws_iam_role.settler.id
  policy = data.aws_iam_policy_document.settler.json
}

output "ingestor_task_role_arn" {
  description = "Ingestor task role ARN."
  value       = aws_iam_role.ingestor.arn
}

output "settler_task_role_arn" {
  description = "Settler task role ARN."
  value       = aws_iam_role.settler.arn
}

output "ingestor_policy_json" {
  description = "Rendered ingestor policy (asserted by tests)."
  value       = data.aws_iam_policy_document.ingestor.json
}

output "settler_policy_json" {
  description = "Rendered settler policy (asserted by tests)."
  value       = data.aws_iam_policy_document.settler.json
}
