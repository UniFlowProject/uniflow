terraform {
  required_version = "1.15.9"

  # Bucket/region come from backend.hcl (gitignored): terraform init -backend-config=backend.hcl
  backend "s3" {
    key          = "lambdas/terraform.tfstate"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      projects = var.project-tag
    }
  }
}

data "aws_caller_identity" "current" {}
