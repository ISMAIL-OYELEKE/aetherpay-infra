terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # Bootstrap starts with local state. After the first apply, uncomment this
  # block and run `terraform init -migrate-state` so the bootstrap state lives
  # in the bucket it created (see README "Bootstrap").
  #
  # backend "s3" {
  #   bucket       = "aetherpay-tfstate-<account_id>-us-east-1"
  #   key          = "bootstrap/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "aetherpay:owner"      = "platform"
      "aetherpay:managed-by" = "terraform"
      "aetherpay:stack"      = "bootstrap"
    }
  }
}
