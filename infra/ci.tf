# GitHub Actions OIDC: one account-wide provider and one least-privilege role per
# deployable repo. CI only ships artifacts (image, SPA build, function code);
# infrastructure changes always go through terraform.

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  ci_roles = {
    academic = {
      sub         = "repo:${var.github_repos.academic}:ref:refs/heads/main"
      policy_name = "ecr-push-and-deploy"
      statements = [
        {
          sid       = "EcrAuth"
          actions   = ["ecr:GetAuthorizationToken"]
          resources = ["*"]
        },
        {
          sid = "EcrPush"
          actions = [
            "ecr:BatchCheckLayerAvailability",
            "ecr:GetDownloadUrlForLayer",
            "ecr:BatchGetImage",
            "ecr:InitiateLayerUpload",
            "ecr:UploadLayerPart",
            "ecr:CompleteLayerUpload",
            "ecr:PutImage",
          ]
          resources = [aws_ecr_repository.academic.arn]
        },
        {
          sid       = "EcsRollout"
          actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
          resources = [aws_ecs_service.academic.id]
        },
      ]
    }

    frontend = {
      sub         = "repo:${var.github_repos.frontend}:environment:${var.github_frontend_environment}"
      policy_name = "spa-deploy"
      statements = [
        {
          sid     = "S3Sync"
          actions = ["s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
          resources = [
            aws_s3_bucket.spa.arn,
            "${aws_s3_bucket.spa.arn}/*",
          ]
        },
        {
          sid       = "CloudFrontInvalidate"
          actions   = ["cloudfront:CreateInvalidation"]
          resources = [aws_cloudfront_distribution.spa.arn]
        },
      ]
    }

    lambdas = {
      sub         = "repo:${var.github_repos.lambdas}:ref:refs/heads/main"
      policy_name = "update-lambda-code"
      statements = [
        {
          sid       = "UpdateLambdaCode"
          actions   = ["lambda:UpdateFunctionCode", "lambda:PublishVersion", "lambda:GetFunction"]
          resources = [for f in aws_lambda_function.this : f.arn]
        },
      ]
    }
  }
}

data "aws_iam_policy_document" "github_actions_assume" {
  for_each = local.ci_roles

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value.sub]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  for_each = local.ci_roles

  name               = "${var.project-tag}-${each.key}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume[each.key].json
}

resource "aws_iam_role_policy" "github_actions" {
  for_each = local.ci_roles

  name = each.value.policy_name
  role = aws_iam_role.github_actions[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for s in each.value.statements : {
      Sid      = s.sid
      Effect   = "Allow"
      Action   = s.actions
      Resource = s.resources
    }]
  })
}
