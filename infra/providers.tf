# AWS providers (default + us-east-1 alias for CloudFront-scoped resources) and shared account/region data sources.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project-tag
    }
  }
}

# CloudFront-scoped resources (WAF, ACM certificates) must live in us-east-1
# regardless of var.aws_region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project = var.project-tag
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
