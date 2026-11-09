###############################################################################
# Immutable settlement ledger journal (system of record, RPO = 0).
#
# DynamoDB global table with Multi-Region Strong Consistency (MRSC): a write
# is acknowledged only after it is durable in a quorum of regions (two full
# replicas + a witness). A conditional put is therefore linearizable across
# regions, which is what the fencing and idempotency design in
# docs/ADR-001-Disaster-Recovery.md relies on.
#
# Item model (single table):
#   pk = "TXN#<settlement_id>"     sk = "ENTRY#<n>"    immutable journal rows
#   pk = "FENCE#<shard>"           sk = "LEASE"        { epoch, holder_region }
#   pk = "BATCH#<batch_id>"        sk = "CLAIM"        { epoch, region }
###############################################################################

variable "name" {
  description = "Name prefix, e.g. aetherpay-production."
  type        = string
}

variable "replica_region" {
  description = "Second full replica region (must be in the same MRSC region set as the primary)."
  type        = string
  default     = "us-east-2"
}

variable "witness_region" {
  description = "Witness region that participates in the write quorum without storing a readable replica."
  type        = string
  default     = "us-west-2"
}

variable "consistency_mode" {
  description = "STRONG (MRSC, RPO 0) or EVENTUAL (MREC, cheaper, RPO > 0)."
  type        = string
  default     = "STRONG"

  validation {
    condition     = contains(["STRONG", "EVENTUAL"], var.consistency_mode)
    error_message = "consistency_mode must be STRONG or EVENTUAL."
  }
}

variable "key_admin_arns" {
  description = "Principals that administer the ledger CMK."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Protect the ledger from deletion."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

data "aws_caller_identity" "current" {}

locals {
  tags         = merge(var.tags, { "aetherpay:module" = "ledger", "aetherpay:data-class" = "financial-ledger" })
  account_root = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

# ---------------------------------------------------------- multi-region CMK
data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:Key policy; Resource "*" means this key only.
  #checkov:skip=CKV_AWS_111:Key policy; Resource "*" means this key only.
  #checkov:skip=CKV_AWS_356:Key policy; Resource "*" means this key only.
  statement {
    sid    = "AccountRootDelegatesToIam"
    effect = "Allow"
    actions = [
      "kms:CancelKeyDeletion", "kms:CreateAlias", "kms:CreateGrant", "kms:Decrypt",
      "kms:DeleteAlias", "kms:DescribeKey", "kms:DisableKey", "kms:EnableKey",
      "kms:EnableKeyRotation", "kms:Encrypt", "kms:GenerateDataKey", "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListGrants", "kms:ListResourceTags",
      "kms:PutKeyPolicy", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:ReplicateKey",
      "kms:RetireGrant", "kms:RevokeGrant", "kms:ScheduleKeyDeletion", "kms:TagResource",
      "kms:UntagResource", "kms:UpdateAlias", "kms:UpdateKeyDescription", "kms:UpdatePrimaryRegion",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  dynamic "statement" {
    for_each = length(var.key_admin_arns) > 0 ? [1] : []

    content {
      sid    = "KeyAdministratorsManageButCannotUse"
      effect = "Allow"
      actions = [
        "kms:CancelKeyDeletion", "kms:CreateAlias", "kms:DeleteAlias", "kms:DescribeKey",
        "kms:DisableKey", "kms:EnableKey", "kms:EnableKeyRotation", "kms:GetKeyPolicy",
        "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListResourceTags", "kms:PutKeyPolicy",
        "kms:ReplicateKey", "kms:ScheduleKeyDeletion", "kms:TagResource", "kms:UntagResource",
        "kms:UpdateAlias", "kms:UpdateKeyDescription",
      ]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.key_admin_arns
      }
    }
  }

  # Required by DynamoDB for tables encrypted with a customer managed key:
  # the service itself (not the caller) reads the key's metadata.
  statement {
    sid    = "AllowDynamoDbToDescribeKey"
    effect = "Allow"
    actions = [
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus",
      "kms:ListAliases", "kms:ListGrants", "kms:ListResourceTags",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["dynamodb.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenyUseOutsideDynamoDb"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:ReEncryptFrom", "kms:ReEncryptTo"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotLike"
      variable = "kms:ViaService"
      values   = ["dynamodb.*.amazonaws.com"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = [local.account_root]
    }
  }
}

resource "aws_kms_key" "ledger" {
  description             = "AetherPay ledger journal (${var.name})"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key.json
  tags                    = local.tags
}

resource "aws_kms_alias" "ledger" {
  name          = "alias/${var.name}-ledger"
  target_key_id = aws_kms_key.ledger.key_id
}

resource "aws_kms_replica_key" "ledger" {
  provider = aws.replica

  description             = "AetherPay ledger journal replica (${var.name})"
  primary_key_arn         = aws_kms_key.ledger.arn
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key.json
  tags                    = local.tags
}

# -------------------------------------------------------------------- table
resource "aws_dynamodb_table" "journal" {
  name                        = "${var.name}-ledger-journal"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.deletion_protection
  stream_enabled              = true
  stream_view_type            = "NEW_AND_OLD_IMAGES" # feeds the Aurora projection

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.ledger.arn
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = 35
  }

  replica {
    region_name                 = var.replica_region
    kms_key_arn                 = aws_kms_replica_key.ledger.arn
    consistency_mode            = var.consistency_mode
    point_in_time_recovery      = true
    deletion_protection_enabled = var.deletion_protection
    propagate_tags              = true
  }

  dynamic "global_table_witness" {
    for_each = var.consistency_mode == "STRONG" ? [var.witness_region] : []

    content {
      region_name = global_table_witness.value
    }
  }

  tags = local.tags
}

# The journal is append-only: nobody, including administrators, may delete or
# overwrite entries through the data plane.
data "aws_iam_policy_document" "journal" {
  statement {
    sid       = "AppendOnlyJournal"
    effect    = "Deny"
    actions   = ["dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.journal.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_dynamodb_resource_policy" "journal" {
  resource_arn = aws_dynamodb_table.journal.arn
  policy       = data.aws_iam_policy_document.journal.json
}

output "table_name" {
  description = "Ledger journal table name."
  value       = aws_dynamodb_table.journal.name
}

output "table_arn" {
  description = "Ledger journal table ARN (primary region)."
  value       = aws_dynamodb_table.journal.arn
}

output "replica_table_arn" {
  description = "Ledger journal table ARN in the replica region."
  value       = "arn:aws:dynamodb:${var.replica_region}:${data.aws_caller_identity.current.account_id}:table/${aws_dynamodb_table.journal.name}"
}

output "stream_arn" {
  description = "Journal stream ARN (primary region)."
  value       = aws_dynamodb_table.journal.stream_arn
}

output "kms_key_arn" {
  description = "Ledger CMK (primary region)."
  value       = aws_kms_key.ledger.arn
}

output "replica_kms_key_arn" {
  description = "Ledger CMK replica."
  value       = aws_kms_replica_key.ledger.arn
}
