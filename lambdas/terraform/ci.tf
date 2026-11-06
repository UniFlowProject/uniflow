# GitHub Actions OIDC deploy role: CI updates function code only (infrastructure changes go
# through terraform). The OIDC provider is account-wide and created by the academic-service
# stack, so it is looked up here: apply that stack first.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.project-tag}-lambdas-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid       = "UpdateLambdaCode"
    actions   = ["lambda:UpdateFunctionCode", "lambda:GetFunction"]
    resources = [for f in aws_lambda_function.this : f.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_deploy" {
  name   = "update-lambda-code"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_deploy.json
}
