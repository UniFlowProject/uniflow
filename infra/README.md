# uniflow infrastructure

One Terraform stack creates the whole platform: network, data, auth, edge, APIs, the academic ECS service, the serverless notifications and the CI roles. A single `terraform apply` brings everything up.

## What the stack owns

| File | Resources |
| --- | --- |
| `network.tf` | VPC, 2 public / 2 private-app / 2 private-data subnets, IGW, optional single NAT (`enable_nat_gateway`, default off) |
| `security.tf` | KMS CMK (`alias/<project>`), GuardDuty, Inspector2 |
| `edge.tf` | SPA S3 bucket, CloudFront (OAC), WAFv2 |
| `dns.tf` | Lookup of the EXISTING Route53 zone (never created), custom-domain ACM certificate + validation/alias records |
| `auth.tf` | Cognito user pool, SPA app client (code flow, `openid email profile`, callback `<origin>/auth/callback`), Hosted UI domain |
| `api.tf` | HTTP API (JWT authorizer, VPC Link, `ANY /api/academic/v2/{proxy+}` and public `GET /api/academic/health` -> internal ALB listener, prefix stripped), WebSocket API and `prod` stage |
| `alb.tf` | Internal ALB in the private-app subnets (SG open to the VPC link only), HTTP :80 listener (default 404), `academic` IP target group (port 3001, health `/health`) and a catch-all forward rule |
| `ecs.tf` | ECS cluster |
| `academic.tf` | ECR repo `uniflow/academic-service`, log group, service SG (+ ingress rule on the RDS SG), execution/task roles, Fargate task definition and ECS service registered in the ALB target group |
| `database.tf` | RDS PostgreSQL (managed password in Secrets Manager) |
| `dynamodb.tf` | DynamoDB `notifications` / `connections` tables |
| `messaging.tf` | SNS topic, 3 SQS queues + DLQs, Scheduler group + role, optional SES identity |
| `lambda_functions.tf`, `lambda_iam.tf` | 10 Lambda functions (zipped from `lambdas/.build` into `.dist/`), log groups, least-privilege execution role per function |
| `lambda_routes.tf`, `lambda_queues.tf` | `/api/notifications/v2/*` routes on the HTTP API, WebSocket authorizer + `$connect`/`$disconnect` routes, SQS event source mappings |
| `observability.tf` | API access log group, alarm topic, DLQ depth alarms |
| `ci.tf` | GitHub OIDC provider and the three CI roles |
| `providers.tf`, `versions.tf`, `backend.tf`, `variables.tf`, `outputs.tf` | Providers (`default_tags` with `Project`), version pins, backend, inputs, outputs |

Notifications are 100% serverless; `uniflow-notification-service` (NestJS) is not deployed.

## Prerequisites

- Terraform 1.15.9 and AWS credentials with admin-level rights on the account.
- An S3 bucket for the state (versioned, encrypted). Copy `backend.hcl.example` to `backend.hcl` and set the bucket; the state key is `uniflow/terraform.tfstate`.
- `terraform.tfvars` (copy `terraform.tfvars.example`). Both `backend.hcl` and `terraform.tfvars` are gitignored.
- Node.js and npm, to stage the Lambda code.

## Apply order

```bash
lambdas/build.sh                                  # stages lambdas/.build/<name>
cd infra
terraform init -backend-config=backend.hcl
terraform apply                                   # desired_count defaults to 0
```

The first apply has no image in ECR, so the academic service starts with `desired_count = 0`. Then:

1. Push an image from the academic repo (its CI workflow, using the `academic` role from `terraform output github_actions_role_arns`).
2. Set `desired_count = 1` (tfvars or `-var`) and `terraform apply` again.

CI owns image rollouts: the ECS service ignores `task_definition` changes and uses the `latest` tag. Re-run `lambdas/build.sh` before any apply that should refresh Lambda code (CI also deploys code on push to `main`).

## CI roles

All roles trust the single GitHub OIDC provider and are created in `ci.tf`. Repos are set by `github_repos`; set the role ARN as the `AWS_ROLE_ARN` variable of the matching repo.

| Role | Repo (default) | Trusted subject | Permissions |
| --- | --- | --- | --- |
| `uniflow-academic-github-actions` | `UniFlowProject/uniflow-academic-service` | `ref:refs/heads/main` | ECR push on the academic repo; `ecs:UpdateService` + `ecs:DescribeServices` on the academic service |
| `uniflow-frontend-github-actions` | `UniFlowProject/uniflow-frontend` | `environment:production` (`github_frontend_environment`) | S3 sync on the SPA bucket; CloudFront invalidation on the distribution |
| `uniflow-lambdas-github-actions` | `UniFlowProject/uniflow` | `ref:refs/heads/main` | `lambda:UpdateFunctionCode`, `PublishVersion`, `GetFunction` on the project's functions (workflow: `.github/workflows/deploy-lambdas.yml`) |

Pull requests touching `infra/` run `.github/workflows/terraform-validate.yml` (`fmt -check`, `init -backend=false`, `validate`; no AWS credentials).

## Cheap demo profile

Defaults and `terraform.tfvars.example` target a low-cost demo. The full profile is a tfvars flip away (see the commented block in the example).

| Variable | Demo | Full |
| --- | --- | --- |
| `enable_waf` | false | true (~US$8/month + requests) |
| `enable_nat_gateway` | false (Fargate in public subnets, public IP, SG only admits the ALB) | true (~US$33/month + data) |
| `rds_multi_az` | false | true (doubles instance cost) |
| `rds_deletion_protection` / `rds_skip_final_snapshot` | false / true | true / false |
| `enable_guardduty` / `enable_inspector` | false | true |
| `ecs_container_insights` | false | true |
| `cognito_deletion_protection` | INACTIVE (demo tfvars) | ACTIVE |

## API routing: internal ALB

The HTTP API reaches ECS through a VPC link and an internal Application Load Balancer (`alb.tf`, about US$16-22/month; no WAF, no NAT, access logs off, deletion protection off). The listener forwards everything to the `academic` target group (IP targets, port 3001, health check `/health`), where the ECS service in `academic.tf` registers its tasks. Routes mirror `docker/floci/init.sh`: `ANY /api/academic/v2/{proxy+}` (JWT) and `GET /api/academic/health` (public), prefix stripped through `overwrite:path`. CloudFront forwards `/api/*` to the API, so the SPA calls `https://<domain>/api/academic/v2/...` same-origin and no API CORS is configured.

## Existing DNS zone

The public zone `uniflow.fabian-vargas.com` (`Z10075302R2CBRQK5WU7F`) is delegated from the registrar and is never created or destroyed by Terraform: `dns.tf` only reads it (`data "aws_route53_zone"`, by `route53_zone_id` or `domain_name`). Terraform manages only the records inside it (ACM validation CNAME, A/AAAA aliases to CloudFront), so the registrar NS delegation survives any destroy and nothing needs to be imported for the zone.

## Migrating from the old 4 stacks

The old stacks were `terraform/` (root, state key `root/...`), `uniflow-academic-service/terraform`, `UniFlow-Frontend/terraform` and `lambdas/terraform`. Their resources have new addresses and the new stack uses its own state, so migrate by recreation (data in RDS/DynamoDB is lost unless backed up first; RDS keeps a final snapshot only if `rds_skip_final_snapshot = false`).

1. Destroy in reverse order, each from its own directory with its own `backend.hcl`: frontend, lambdas, academic, root (`terraform destroy`). The academic stack destroys the GitHub OIDC provider, which the new stack recreates (only one per account can exist). If the root stack's destroy is blocked (RDS or Cognito deletion protection), set those variables to the unprotected values and apply first.
2. The Route53 zone needs no action: it is only a data source in the old root stack, so `destroy` does not touch it and no `terraform state rm` is required. Only the validation and alias records inside it are removed and recreated by the new stack.
3. Apply the new stack as described in "Apply order". If you chose to keep any old resource instead of destroying it (for example the OIDC provider), adopt it with `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com` before the first apply.
4. Delete the old state objects (`root/`, `academic/`, `frontend/`, `lambdas/` keys) from the state bucket once the new stack is healthy.

The old SSM contract parameters (`/uniflow/*`) are no longer published: nothing in the repos read them.

## Assumptions and follow-ups

- The RDS secret uses the default Secrets Manager key. Consider a `postgres` parameter group with `rds.force_ssl=1`.
- SNS subscriptions use the SNS envelope (raw delivery off).
- GuardDuty: leave `enable_guardduty=false` if the account already has a detector.
- SPA fallback uses a CloudFront Function on the default behavior instead of distribution-wide 403/404 custom error responses, so real API 403/404 responses are not rewritten to `index.html`.
- The WebSocket stage depends on the WebSocket routes so the first deployment is not empty.
