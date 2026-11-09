# Offline unit tests: `terraform test` runs a plan with a credential-less
# provider and overridden identity data sources. No AWS account is needed.

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
  name             = "aetherpay-test"
  azs              = ["us-east-1a", "us-east-1b", "us-east-1c"]
  logs_kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-0000-0000-000000000000"
}

run "cidr_plan_matches_design" {
  command = plan

  assert {
    condition     = local.public_cidrs == ["10.24.0.0/26", "10.24.0.64/26", "10.24.0.128/26"]
    error_message = "Public tier CIDRs drifted from the documented plan."
  }

  assert {
    condition     = local.isolated_cidrs == ["10.24.1.0/25", "10.24.1.128/25", "10.24.2.0/25"]
    error_message = "Isolated tier CIDRs drifted from the documented plan."
  }

  assert {
    condition     = local.app_cidrs == ["10.24.4.0/22", "10.24.8.0/22", "10.24.12.0/22"]
    error_message = "App tier CIDRs drifted from the documented plan."
  }
}

run "no_cidr_overlaps_and_all_inside_vpc" {
  command = plan

  assert {
    # Two CIDRs overlap iff their network addresses match when both are
    # truncated to the shorter of the two prefix lengths.
    condition = alltrue(flatten([
      for i, a in local.all_cidrs : [
        for j, b in local.all_cidrs :
        i == j || (
          cidrhost("${cidrhost(a, 0)}/${min(tonumber(split("/", a)[1]), tonumber(split("/", b)[1]))}", 0) !=
          cidrhost("${cidrhost(b, 0)}/${min(tonumber(split("/", a)[1]), tonumber(split("/", b)[1]))}", 0)
        )
      ]
    ]))
    error_message = "Subnet CIDRs overlap."
  }

  assert {
    condition = alltrue([
      for c in local.all_cidrs :
      cidrhost("${cidrhost(c, 0)}/20", 0) == "10.24.0.0"
    ])
    error_message = "A subnet falls outside 10.24.0.0/20."
  }
}

run "app_and_isolated_tiers_have_no_internet_route" {
  command = plan

  assert {
    condition     = length(aws_route.app_allowlisted_egress) == 0
    error_message = "The app tier must not have any NAT route by default."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "NAT gateways must be opt-in."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.app : s.map_public_ip_on_launch == false])
    error_message = "App subnets must never auto-assign public IPs."
  }
}

run "rejects_arbitrary_nat_egress" {
  command = plan

  variables {
    enable_nat_gateway = true
    nat_egress_cidrs   = ["0.0.0.0/0"]
  }

  expect_failures = [var.nat_egress_cidrs]
}

run "rejects_non_slash20_vpc" {
  command = plan

  variables {
    vpc_cidr = "10.24.0.0/16"
  }

  expect_failures = [var.vpc_cidr]
}
