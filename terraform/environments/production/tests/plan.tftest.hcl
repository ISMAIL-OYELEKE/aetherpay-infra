# Multi-region production smoke test with mocked AWS providers: proves the module
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
  alias = "secondary"

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-2"
      name   = "us-east-2"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
}

mock_provider "aws" {
  alias = "arc"
}

variables {
  app_image_primary        = "111122223333.dkr.ecr.us-east-1.amazonaws.com/aetherpay/app@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  app_image_secondary      = "111122223333.dkr.ecr.us-east-2.amazonaws.com/aetherpay/app@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  ecr_repository_arn       = "arn:aws:ecr:us-east-1:111122223333:repository/aetherpay/app"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/aetherpay-workload-boundary"
}

run "production_plans_both_regions" {
  command = plan

  assert {
    condition     = output.global_webhook_url == "https://webhooks.example.com/webhooks/"
    error_message = "Global webhook URL is wrong."
  }
}
