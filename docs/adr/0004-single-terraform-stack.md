# 0004. One Terraform stack in infra/

- Status: Accepted
- Date: 2026-11

## Context

Infrastructure was split into four stacks with separate state: a shared root stack (`terraform/`), one inside the academic repo, one inside the frontend repo and one for the Lambdas. They were coupled through SSM parameters (`/uniflow/*`). The GitHub OIDC provider, which only one can exist per AWS account, was owned by the academic stack, so destroying that stack broke CI everywhere.

## Decision

Merge everything into a single stack in `infra/` (commits `b52a198`, `a1ea6ec`): network, data, auth, edge, APIs, the academic ECS service, the serverless notifications and the CI roles. State is in S3 under the key `uniflow/terraform.tfstate`.

- Resources got new addresses, so the migration is by recreation, not `terraform state mv`. `infra/README.md` lists the pre-steps (freeze CI, RDS snapshot, DynamoDB backup, Cognito user export) and the destroy order.
- The SSM contract parameters are not published any more; nothing read them.
- CI ownership is split deliberately: Terraform owns infrastructure and the ECS task definition; CI only ships artifacts (image, SPA build, function code). Lambda code uses `ignore_changes` on `filename` and `source_code_hash`.
- Pull requests touching `infra/` run `terraform fmt -check`, `init -backend=false` and `validate` without AWS credentials (`.github/workflows/terraform-validate.yml`).

## Consequences

- One `terraform apply` brings the platform up; cross-stack references are plain resource references and need no SSM indirection.
- A larger blast radius per apply and a single state to protect; there is no plan/apply automation in CI, apply is run by hand.
- Data in RDS and DynamoDB is lost on the recreate migration unless backed up first.
- The old `terraform/` directories in the academic and frontend repos are superseded by `infra/` and should be removed there; as of this writing they are still present.
