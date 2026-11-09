# Whole-environment smoke test with mocked AWS providers: proves the module
# graph wires up and plans end to end (counts, for_each keys, cross-module
# references) without an AWS account.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
      name   = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

mock_provider "aws" {
  alias = "replica"
}

variables {
  domain_name              = "webhooks.staging.example.com"
  hosted_zone_id           = "Z0123456789ABCDEFGHIJ"
  app_image                = "111122223333.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  ecr_repository_arn       = "arn:aws:ecr:us-east-1:111122223333:repository/aetherpay/app"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/aetherpay-workload-boundary"
}

run "staging_plans_end_to_end" {
  command = plan

  assert {
    condition     = output.cidr_allocation.app == ["10.24.4.0/22", "10.24.8.0/22", "10.24.12.0/22"]
    error_message = "Staging app tier CIDRs are wrong."
  }
}

run "rejects_mutable_image_tags" {
  command = plan

  variables {
    app_image = "111122223333.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app:latest"
  }

  expect_failures = [var.app_image]
}
