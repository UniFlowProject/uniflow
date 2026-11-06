# 0001. Reach ECS through API Gateway, a VPC link and an internal ALB

- Status: Accepted
- Date: 2026-11

## Context

The academic service runs on ECS Fargate in private subnets and must be exposed to the browser through an API Gateway HTTP API, with Cognito JWT validation at the gateway. The first version registered the service in a private Cloud Map namespace and pointed the VPC link integration at it.

That did not work: commit `ee18d14` records that "API Gateway could not resolve the Cloud Map instance (no port), returning 500".

## Decision

Put an internal Application Load Balancer between the VPC link and the tasks:

```
HTTP API -> VPC link -> internal ALB (:80) -> target group (IP targets) -> ECS tasks
```

- The ALB lives in the private-app subnets. Its security group admits only the VPC link security group (`infra/alb.tf`, `infra/api.tf`).
- The listener's default action is a fixed 404; a catch-all rule forwards to the `academic` target group (port `container_port`, default 3001, health check `/health`).
- The API routes are `ANY /api/academic/v2/{proxy+}` (JWT authorizer) and a public `GET /api/academic/health`. The `/api/academic` prefix is stripped with `overwrite:path` before the request reaches the service.
- The ECS service registers its tasks in the target group (`infra/academic.tf`), so Terraform owns the wiring and the task IP changes do not matter to the gateway.
- CloudFront forwards `/api/*` to the HTTP API, so the SPA calls the API same-origin and no API CORS is configured (`infra/api.tf`, `infra/edge.tf`).

## Consequences

- Positive: a supported integration target with health checks and a stable listener port; Cloud Map and its namespace are gone.
- Negative: the ALB adds a fixed monthly cost. `infra/README.md` estimates US$16-22 per month; that figure is the author's estimate, not a measurement.
- Adding another service means adding a target group and a listener rule (path-based) rather than a service-discovery entry. Not yet done: only `academic` is routed.
- The ALB has no WAF, access logs or deletion protection in the demo profile.
