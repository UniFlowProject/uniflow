# Authentication: Cognito user pool, SPA app client and optional hosted-UI domain.

locals {
  site_url           = local.custom_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.spa.domain_name}"
  cognito_issuer_uri = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"

  # Origins allowed to host the SPA (CloudFront/custom domain plus local dev).
  # The SPA signs in through the Hosted UI and returns to <origin>/auth/callback.
  app_origins   = distinct(concat([local.site_url], var.cognito_app_origins))
  callback_urls = [for o in local.app_origins : "${o}/auth/callback"]
}

resource "aws_cognito_user_pool" "this" {
  name                     = "${var.project-tag}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = var.cognito_deletion_protection

  password_policy {
    minimum_length    = 10
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = {
    Name     = "${var.project-tag}-users"
    projects = var.project-tag
  }
}

resource "aws_cognito_user_pool_client" "spa" {
  name         = "${var.project-tag}-spa"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = local.callback_urls
  logout_urls                          = local.app_origins
}

resource "aws_cognito_user_pool_domain" "this" {
  count        = var.cognito_domain_prefix != null ? 1 : 0
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}
