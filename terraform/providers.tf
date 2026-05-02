terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.43"
    }
  }
}

provider "aws" {
  region = "ap-southeast-4"

  default_tags {
    tags = {
      Repo      = var.repo
      ManagedBy = "terraform"
    }
  }
}
