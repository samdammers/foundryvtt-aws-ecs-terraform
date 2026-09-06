terraform {
  required_version = ">= 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.43"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Repo      = var.repo
      ManagedBy = "terraform"
    }
  }
}

# CloudFront ACM certificates must be issued in us-east-1 regardless of deployment region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Repo      = var.repo
      ManagedBy = "terraform"
    }
  }
}
