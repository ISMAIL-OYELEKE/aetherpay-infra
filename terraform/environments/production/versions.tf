terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  backend "s3" {
    key          = "production/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = local.default_tags
  }
}

# Route 53 ARC's configuration API is homed in us-west-2.
provider "aws" {
  alias  = "arc"
  region = "us-west-2"

  default_tags {
    tags = local.default_tags
  }
}
