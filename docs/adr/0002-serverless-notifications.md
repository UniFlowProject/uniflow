# 0002. Serverless notifications instead of the NestJS service

- Status: Accepted
- Date: 2026-11

## Context

Notifications were first built as `uniflow-notification-service`: NestJS, MongoDB and Socket.IO. When the platform moved to AWS, the repository's own README ("Why it was replaced") gives three reasons:

- It was backed by MongoDB, an extra stateful dependency to run and pay for.
- Socket.IO (stateful, long-lived connections) does not fit API Gateway WebSocket.
- An always-on container costs more than pay-per-use Lambdas for this traffic.

## Decision

Rebuild notifications as a serverless stack, defined in `infra/` with code in `lambdas/` (11 functions, Node.js, `lambdas/build.sh` stages them):

- REST: HTTP API routes under `/api/notifications/v2/*`, each backed by a Lambda (create, list, unread-count, mark-read, delete), protected by the Cognito JWT authorizer.
- Storage: DynamoDB tables `notifications` (key `user_id` / `notification_id`) and `connections` (key `connection_id`, index on `user_id`, TTL attribute).
- Real time: WebSocket API with a Lambda REQUEST authorizer reading the Cognito token from the `token` query string, plus `$connect` and `$disconnect` Lambdas that maintain the `connections` table. Push uses `PostToConnection`.
- Async pipeline: EventBridge Scheduler writes to an `expirations` SQS queue; `process_expiration` publishes to an SNS topic; SNS fans out to `in-app-notifications` and `email-notifications` queues; their consumers push over the WebSocket or send email through SES. Each queue has a DLQ.

Flow diagrams are in [docs/architecture.md](../architecture.md).

## Consequences

- No servers or MongoDB to operate for notifications; the Lambdas have least-privilege roles per function (`infra/lambda_iam.tf`).
- More moving parts in Terraform (queues, mappings, routes) and distributed failure modes; DLQ depth alarms exist in `infra/observability.tf`, and there are no alarms on other signals.
- Lambda code is shipped by CI (`.github/workflows/deploy-lambdas.yml`); Terraform ignores code changes after the first create.
- The NestJS service is archived. It remains only as a local stand-in in `docker-compose.dev.yml`, so the local and AWS notification implementations differ (see [local development](../local-development.md)).
