# 0005. GitHub Actions OIDC roles per repository

- Status: Accepted
- Date: 2026-11

## Context

Three repositories deploy to AWS from GitHub Actions: the academic service (container image), the frontend (static site) and the central repo (Lambda code). Storing long-lived IAM access keys as GitHub secrets would leave permanent credentials outside AWS.

## Decision

Use GitHub's OIDC provider and one IAM role per deployable repo, all defined in `infra/ci.tf`. Workflows request `id-token: write`, assume the role with `aws-actions/configure-aws-credentials`, and read its ARN from the `AWS_ROLE_ARN` repository variable.

| Role | Trusted subject | Permissions |
| --- | --- | --- |
| academic | `ref:refs/heads/main` | ECR push on the academic repository; `ecs:UpdateService` and `ecs:DescribeServices` on its service |
| frontend | `environment:production` | S3 sync on the SPA bucket; CloudFront invalidation on the distribution |
| lambdas | `ref:refs/heads/main` | `lambda:UpdateFunctionCode`, `PublishVersion`, `GetFunction` on the project's functions |

CI ships artifacts only; infrastructure changes always go through Terraform.

## Consequences

- No AWS keys in GitHub; credentials are short-lived and scoped to one repo and one ref or environment.
- The trust is only as strong as the GitHub-side settings: anyone who can push to `main` in the academic or central repo can deploy, and the frontend role trusts the `production` environment from any ref. Branch protection and environment rules must be configured on GitHub (listed in `infra/README.md`); they are not enforced by this repository.
- Only one OIDC provider can exist per account, so it lives in this stack only (see ADR 0004).
