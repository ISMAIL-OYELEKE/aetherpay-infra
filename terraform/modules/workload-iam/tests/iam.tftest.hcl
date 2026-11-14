# Policy-as-code unit tests for the workload identities. Policies are rendered
# locally by aws_iam_policy_document, so no AWS account is needed.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "offline-test"
  secret_key                  = "offline-test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111122223333"
    arn        = "arn:aws:iam::111122223333:user/test"
    user_id    = "TEST"
  }
}

override_data {
  target = data.aws_region.current
  values = {
    region = "us-east-1"
    name   = "us-east-1"
  }
}

variables {
  name = "aetherpay-test"
  vpce_ids = {
    secretsmanager = "vpce-0secretsmanager0000"
    sqs            = "vpce-0sqs000000000000000"
    dynamodb       = "vpce-0dynamodb0000000000"
  }
  secrets_kms_key_arn         = "arn:aws:kms:us-east-1:111122223333:key/11111111-1111-1111-1111-111111111111"
  data_kms_key_arn            = "arn:aws:kms:us-east-1:111122223333:key/22222222-2222-2222-2222-222222222222"
  ledger_kms_key_arn          = "arn:aws:kms:us-east-1:111122223333:key/mrk-33333333333333333333333333333333"
  partner_hmac_secret_arn     = "arn:aws:secretsmanager:us-east-1:111122223333:secret:aetherpay-test/signing/partner-webhook-hmac-AbCdEf"
  custodian_signer_secret_arn = "arn:aws:secretsmanager:us-east-1:111122223333:secret:aetherpay-test/signing/custodian-request-signer-GhIjKl"
  ingestion_queue_arn         = "arn:aws:sqs:us-east-1:111122223333:aetherpay-test-ingestion"
  ledger_table_arn            = "arn:aws:dynamodb:us-east-1:111122223333:table/aetherpay-test-ledger-journal"
  cache_replication_group_arn = "arn:aws:elasticache:us-east-1:111122223333:replicationgroup:aetherpay-test-cache"
  cache_user_arn              = "arn:aws:elasticache:us-east-1:111122223333:user:aetherpay-test-ingestor"
  db_cluster_resource_id      = "cluster-ABCDEFGHIJKLMNOP"
}

run "no_wildcards_on_sensitive_services" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [output.ingestor_policy_json, output.settler_policy_json] : [
        for st in jsondecode(doc).Statement : [
          for a in flatten([st.Action]) :
          !(can(regex("^(kms|secretsmanager|s3|dynamodb|sqs|rds-db|elasticache):", a)) && (
            strcontains(a, "*") || contains(flatten([st.Resource]), "*")
          ))
        ]
      ]
    ]))
    error_message = "A KMS, Secrets Manager, storage or queue statement uses a wildcard action or resource."
  }
}

run "secret_queue_and_ledger_access_pinned_to_vpc_endpoints" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [output.ingestor_policy_json, output.settler_policy_json] : [
        for st in jsondecode(doc).Statement :
        can(st.Condition.StringEquals["aws:SourceVpce"])
        if length([for a in flatten([st.Action]) : a if can(regex("^(secretsmanager|sqs|dynamodb):", a))]) > 0
      ]
    ]))
    error_message = "Every Secrets Manager, SQS and DynamoDB statement must carry an aws:SourceVpce condition."
  }
}

run "kms_use_restricted_to_owning_service" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [output.ingestor_policy_json, output.settler_policy_json] : [
        for st in jsondecode(doc).Statement :
        can(st.Condition.StringEquals["kms:ViaService"])
        if length([for a in flatten([st.Action]) : a if startswith(a, "kms:")]) > 0
      ]
    ]))
    error_message = "KMS permissions must be limited with kms:ViaService."
  }
}

run "ingestor_cannot_touch_ledger_and_settler_cannot_read_partner_key" {
  command = plan

  assert {
    condition     = !strcontains(output.ingestor_policy_json, "dynamodb:")
    error_message = "The ingestor must not have ledger permissions."
  }

  assert {
    condition     = !strcontains(output.settler_policy_json, var.partner_hmac_secret_arn)
    error_message = "The settler must not be able to read the inbound partner HMAC key."
  }

  assert {
    condition     = !strcontains(output.settler_policy_json, "dynamodb:DeleteItem")
    error_message = "The ledger is append-only; DeleteItem must never be granted."
  }
}

run "ledger_writes_limited_by_key_prefix" {
  command = plan

  # Every PutItem/UpdateItem grant must be scoped to item key prefixes, and
  # journal rows (TXN#) may be created with PutItem but never updated.
  assert {
    condition = alltrue([
      for st in jsondecode(output.settler_policy_json).Statement :
      can(st.Condition["ForAllValues:StringLike"]["dynamodb:LeadingKeys"])
      if length(setintersection(toset(flatten([st.Action])), toset(["dynamodb:PutItem", "dynamodb:UpdateItem"]))) > 0
    ])
    error_message = "Ledger write grants must carry a dynamodb:LeadingKeys condition."
  }

  assert {
    condition = alltrue([
      for st in jsondecode(output.settler_policy_json).Statement :
      !contains(flatten([st.Condition["ForAllValues:StringLike"]["dynamodb:LeadingKeys"]]), "TXN#*")
      if contains(flatten([st.Action]), "dynamodb:UpdateItem")
    ])
    error_message = "Journal rows (TXN#) must never be updatable."
  }

  assert {
    condition     = !strcontains(output.settler_policy_json, "dynamodb:BatchWriteItem")
    error_message = "BatchWriteItem would bypass the per-item conditions; never grant it."
  }
}
