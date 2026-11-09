terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # Partial configuration: bucket and kms_key_id come from the bootstrap
  # outputs via -backend-config (see backend.hcl.example and the CI workflows).
  backend "s3" {
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3 native state locking
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}

# Second ledger replica region (MRSC quorum member).
provider "aws" {
  alias  = "replica"
  region = var.ledger_replica_region

  default_tags {
    tags = local.default_tags
  }
}
