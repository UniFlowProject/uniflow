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
| `api.tf` | HTTP API (JWT authorizer, VPC Link, `ANY /api/academic/v2/{proxy+}` and public `GET /api/academic/health` -> internal ALB listener, prefix stripped), WebSocket API shell |
| `alb.tf` | Internal ALB in the private-app subnets (SG open to the VPC link only), HTTP :80 listener (default 404), `academic` IP target group (port 3001, health `/health`) and a catch-all forward rule |
| `ecs.tf` | ECS cluster (`create_ecs_cluster`, default true; single owner), cluster name/ARN locals |
| `database.tf` | RDS PostgreSQL (managed password in Secrets Manager) |
| `dynamodb.tf` | DynamoDB `notifications` / `connections` tables |
| `messaging.tf` | SNS topic, 3 SQS queues + DLQs, Scheduler group + role, optional SES identity |
| `observability.tf` | API access log group, alarm topic, DLQ depth alarms |
| `ssm.tf` | `/<project>/<name>` contract parameters |
| `providers.tf`, `versions.tf`, `backend.tf`, `variables.tf`, `outputs.tf` | Providers, version pins, backend template, inputs, outputs |

Owned by other stacks: ECS services/task defs (they register into the ALB target groups), ECR, service log groups, GitHub OIDC roles, and the serverless notifications stack in `lambdas/terraform` (Lambda functions and roles, `/api/notifications/v2/*` HTTP routes on this stack's JWT authorizer, WebSocket routes + authorizer, SQS event source mappings, CI deploy role). Notifications are 100% serverless; `uniflow-notification-service` (NestJS) is not deployed.

## Apply order

1. `cp backend.hcl.example backend.hcl`, edit, uncomment `backend.tf`, then `terraform init -backend-config=backend.hcl` (or `terraform init` for local state).
2. `terraform apply` this stack first (existing VPC resources keep their addresses).
3. Then apply `uniflow-academic-service/terraform` (it creates the account-wide GitHub OIDC provider), then `lambdas/terraform` (run `lambdas/build.sh` first; see `lambdas/terraform` variables for `ses_sender_email` / `default_to_email`).

## Reading outputs from a service repo

```hcl
data "aws_ssm_parameter" "target_group" { name = "/uniflow/academic_target_group_arn" }
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

## API routing: internal ALB

The HTTP API reaches ECS through a VPC link and an internal Application Load Balancer (`alb.tf`, about US$16-22/month; no WAF, no NAT, access logs off, deletion protection off). The VPC link integrations point at the ALB listener ARN; the listener forwards everything to the `academic` target group (IP targets, port 3001, health check `/health`). The ECS service in `uniflow-academic-service/terraform` registers itself in that target group and allows port 3001 only from the ALB security group. AWS Cloud Map was dropped: API Gateway private integrations resolve a Cloud Map instance through its port, and the ECS-registered instance had none, so the integration returned 500.

Routes mirror `docker/floci/init.sh`: `ANY /api/academic/v2/{proxy+}` (JWT) and `GET /api/academic/health` (public), with the prefix stripped through `overwrite:path`. In production CloudFront forwards `/api/*` to the API, so the SPA calls `https://<domain>/api/academic/v2/...` same-origin and no API CORS is configured.

SSM contract parameters for the ALB: `/<project>/alb_sg_id`, `/<project>/alb_listener_arn`, `/<project>/academic_target_group_arn` (the former `cloudmap_*` parameters were removed).

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
- WebSocket stage `prod` is created with no routes; the `lambdas/terraform` stack adds `$connect` / `$disconnect` (auto-deploy is on). If AWS rejects the empty deployment, apply `lambdas/terraform` first for the stage.
- State is local until the S3 backend in `backend.tf` is enabled (see `backend.hcl.example`).
- `terraform apply` was not run; only `fmt`, `init`, `validate` and `plan`.
