terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.43"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
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
