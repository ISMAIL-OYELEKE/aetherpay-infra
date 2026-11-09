###############################################################################
# Remote state: S3 with SSE-KMS (CMK), versioning, TLS-only access and S3
# native state locking (use_lockfile = true, Terraform >= 1.10). No DynamoDB
# lock table is needed.
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  account_root = "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"
  state_bucket = "aetherpay-tfstate-${local.account_id}-${var.region}"
}

data "aws_iam_policy_document" "state_key" {
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
      "kms:PutKeyPolicy", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:RevokeGrant",
      "kms:ScheduleKeyDeletion", "kms:TagResource", "kms:UntagResource", "kms:UpdateAlias",
      "kms:UpdateKeyDescription",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform state encryption for AetherPay"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json
}

resource "aws_kms_alias" "state" {
  name          = "alias/aetherpay-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:State access is audited through CloudTrail S3 data events at the account level.
  #checkov:skip=CKV_AWS_144:Versioned single-region state; DR copy is handled by AWS Backup at the account level.
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days           = 90
      newer_noncurrent_versions = 20
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyObjectsNotEncryptedWithStateKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.state.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}
