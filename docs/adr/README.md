# Architecture decision records

Short records of the decisions that shape the platform. Each follows Context, Decision, Consequences. Dates are the month the decision landed in the code.

| ADR | Title |
| --- | --- |
| [0001](0001-api-gateway-vpc-link-internal-alb.md) | Reach ECS through API Gateway, a VPC link and an internal ALB |
| [0002](0002-serverless-notifications.md) | Serverless notifications instead of the NestJS service |
| [0003](0003-tasks-merged-into-academic.md) | Merge tasks into the academic service |
| [0004](0004-single-terraform-stack.md) | One Terraform stack in infra/ |
| [0005](0005-github-actions-oidc-roles.md) | GitHub Actions OIDC roles per repository |

See also [docs/architecture.md](../architecture.md) for diagrams.
