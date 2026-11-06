# uniflow shared infrastructure

Shared layer only. Services and Lambdas live in their own repos and consume this stack through SSM parameters.

## What this stack owns

| File | Resources |
| --- | --- |
| `network.tf` | VPC, 2 public / 2 private-app / 2 private-data subnets, IGW, optional single NAT (`enable_nat_gateway`, default off) |
| `security.tf` | KMS CMK (`alias/<project>`), GuardDuty, Inspector2 |
| `edge.tf` | SPA S3 bucket, CloudFront (OAC), WAFv2 |
| `dns.tf` | Lookup of the EXISTING Route53 zone (never created), custom-domain ACM certificate + validation/alias records |
| `auth.tf` | Cognito user pool, SPA app client (code flow, `openid email profile`, callback `<origin>/auth/callback`), Hosted UI domain |
| `api.tf` | HTTP API (JWT authorizer, VPC Link, `ANY /api/academic/v2/{proxy+}` and public `GET /api/academic/health` -> Cloud Map, prefix stripped), WebSocket API shell |
| `discovery.tf` | Private Cloud Map namespace `<project>.local` and the `academic` service entry |
| `ecs.tf` | ECS cluster (`create_ecs_cluster`, default true; single owner), cluster name/ARN locals |
| `database.tf` | RDS PostgreSQL (managed password in Secrets Manager) |
| `dynamodb.tf` | DynamoDB `notifications` / `connections` tables |
| `messaging.tf` | SNS topic, 3 SQS queues + DLQs, Scheduler group + role, optional SES identity |
| `observability.tf` | API access log group, alarm topic, DLQ depth alarms |
| `ssm.tf` | `/<project>/<name>` contract parameters |
| `providers.tf`, `versions.tf`, `backend.tf`, `variables.tf`, `outputs.tf` | Providers, version pins, backend template, inputs, outputs |

Owned by other repos: ECS services/task defs (they register into Cloud Map), ECR, service log groups, GitHub OIDC roles, Lambda functions, and their HTTP/WebSocket routes, integrations and WebSocket authorizer.

## Apply order

1. `cp backend.hcl.example backend.hcl`, edit, uncomment `backend.tf`, then `terraform init -backend-config=backend.hcl` (or `terraform init` for local state).
2. `terraform apply` this stack first (existing VPC resources keep their addresses).
3. Then apply `uniflow-academic-service/terraform`, and the lambdas repo.

## Reading outputs from a service repo

```hcl
data "aws_ssm_parameter" "registry" { name = "/uniflow/cloudmap_academic_service_arn" }
data "aws_ssm_parameter" "subnets"  { name = "/uniflow/public_subnet_ids" }

locals { subnet_ids = split(",", data.aws_ssm_parameter.subnets.value) }
```

## Cheap demo profile

Defaults and `terraform.tfvars.example` target a low-cost demo. The full profile is a tfvars flip away (see the commented block in the example).

| Variable | Demo | Full |
| --- | --- | --- |
| `enable_waf` | false | true (~US$8/month + requests) |
| `enable_nat_gateway` | false (Fargate in public subnets, public IP, SG only admits the VPC link) | true (~US$33/month + data) |
| `rds_multi_az` | false | true (doubles instance cost) |
| `rds_deletion_protection` / `rds_skip_final_snapshot` | false / true | true / false |
| `enable_guardduty` / `enable_inspector` | false | true |
| `ecs_container_insights` | false | true |
| `cognito_deletion_protection` | INACTIVE (demo tfvars) | ACTIVE |

## API routing: Cloud Map instead of an ALB

The HTTP API reaches ECS through a VPC link and an AWS Cloud Map service (`academic.<project>.local`); there is no load balancer (an internal ALB would add about US$16-22/month). Routes mirror `docker/floci/init.sh`: `ANY /api/academic/v2/{proxy+}` (JWT) and `GET /api/academic/health` (public), with the prefix stripped through `overwrite:path`. In production CloudFront forwards `/api/*` to the API, so the SPA calls `https://<domain>/api/academic/v2/...` same-origin and no API CORS is configured.

## Existing DNS zone

The public zone `uniflow.fabian-vargas.com` is delegated from the registrar and shared across rebuilds, so it is only read (`data "aws_route53_zone"`, by `route53_zone_id` or by `domain_name`). Terraform only adds the ACM validation CNAME and the A/AAAA alias records inside it.

## Assumptions and follow-ups

- This stack owns the ECS cluster (`create_ecs_cluster = true`). `uniflow-academic-service/terraform` only reads its ARN from SSM and creates ECR, its SG, log group, IAM roles and the GitHub OIDC provider (account-wide, one per account).
- The academic stack needs this stack applied first (it reads the `/<project>/*` SSM contract), so it cannot be planned before then.
- The ECR repo starts empty: apply the academic stack with `-var desired_count=0`, push an image (CI), then apply with the default `desired_count = 1`.
- SPA fallback uses a CloudFront Function on the default behavior instead of distribution-wide 403/404 custom error responses, so real API 403/404 responses are not rewritten to `index.html`.
- The RDS secret uses the default Secrets Manager key; consumers need `secretsmanager:GetSecretValue` on `rds_secret_arn`. Consider a `postgres` parameter group with `rds.force_ssl=1`.
- SNS subscriptions use the SNS envelope (raw delivery off).
- GuardDuty: leave `enable_guardduty=false` if the account already has a detector.
- WebSocket stage `prod` is created with no routes; if AWS rejects an empty deployment, create it after the lambdas repo adds routes.
- State is local until the S3 backend in `backend.tf` is enabled (see `backend.hcl.example`).
- `terraform apply` was not run; only `fmt`, `init`, `validate` and `plan`.
