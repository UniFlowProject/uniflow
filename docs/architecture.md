# Architecture

Diagrams of the deployed platform (AWS, one Terraform stack in [`infra/`](../infra/)). Names match the Terraform resources. Decisions are explained in [docs/adr](adr/README.md).

## System

![UniFlow AWS architecture](../diagrams/Uniflow%20AWS%20Diagram%20Architecture.jpg)

Editable source: [diagrams/Uniflow.drawio](../diagrams/Uniflow.drawio).

The browser loads the SPA from CloudFront and calls `/api/*` on the same origin. CloudFront forwards `/api/*` to the HTTP API. Academic requests go through a VPC link to an internal ALB and on to ECS Fargate; notification requests go straight to Lambda. Both are protected by the same Cognito JWT authorizer.

```mermaid
flowchart LR
  user["Browser"]
  cf["CloudFront<br/>(+ optional WAF)"]
  s3[("S3<br/>SPA bucket")]
  cognito["Cognito<br/>user pool + Hosted UI"]

  user --> cf
  cf -->|"default behavior"| s3
  cf -->|"/api/*"| http["API Gateway<br/>HTTP API"]
  user -.->|"login (code + PKCE)"| cognito
  http -.->|"JWT authorizer"| cognito

  subgraph vpc["VPC"]
    link["VPC link"]
    alb["Internal ALB"]
    ecs["ECS Fargate<br/>academic service<br/>(Spring Boot)"]
    rds[("RDS PostgreSQL")]
    link --> alb --> ecs --> rds
  end

  http -->|"/api/academic/v2/*"| link

  subgraph notif["Serverless notifications"]
    rest["REST Lambdas"]
    ddb[("DynamoDB<br/>notifications")]
    rest --> ddb
  end

  http -->|"/api/notifications/v2/*"| rest
  user <-->|"WebSocket"| ws["API Gateway<br/>WebSocket API"]
  ecs -->|"task reminders"| sched["EventBridge<br/>Scheduler"]
```

The notification pipeline behind the Scheduler is drawn below.

## CI/CD

![CI/CD pipelines](../diagrams/Uniflow%20AWS%20Diagram%20CICD.jpg)

Each deployable repository has one GitHub Actions workflow and one IAM role assumed through GitHub OIDC (no stored AWS keys, see [ADR 0005](adr/0005-github-actions-oidc-roles.md)). CI ships artifacts only; infrastructure is applied with Terraform by hand.

```mermaid
flowchart TD
  subgraph academic["uniflow-academic-service (push to main)"]
    a1["Maven build"] --> a2["docker build + push<br/>tags: sha and latest"]
    a2 --> a3["ecs update-service<br/>--force-new-deployment"]
  end
  subgraph frontend["uniflow-frontend (push to main, environment production)"]
    f1["pnpm build"] --> f2["s3 sync --delete"] --> f3["CloudFront invalidation"]
  end
  subgraph central["uniflow (push to main under lambdas/)"]
    l1["npm test per Lambda"] --> l2["lambdas/build.sh"] --> l3["lambda update-function-code<br/>--publish"]
  end
  subgraph pr["uniflow (pull request touching infra/)"]
    p1["terraform fmt -check<br/>init -backend=false<br/>validate"]
  end

  oidc{{"GitHub OIDC provider<br/>+ one IAM role per repo (infra/ci.tf)"}}
  a2 -.-> oidc
  f2 -.-> oidc
  l3 -.-> oidc
  oidc --> ecr[("ECR")]
  oidc --> ecsx["ECS service"]
  oidc --> s3x[("S3 + CloudFront")]
  oidc --> lam["Lambda functions"]
```

The `terraform-validate` job uses no AWS credentials.

## Notification flow

Reminders start in the academic service (when `reminder_scheduler = "eventbridge"`, see `infra/academic.tf`), which creates one one-shot EventBridge Scheduler schedule per task. When it fires, the message lands in the `expirations` queue and fans out through SNS to the in-app and email queues. Every queue has a DLQ.

```mermaid
flowchart LR
  ecs["Academic service"] -->|"create/delete schedule"| sched["EventBridge Scheduler<br/>group uniflow"]
  sched -->|"at due date - lead time"| qexp["SQS expirations"]
  qexp --> pe["Lambda<br/>process_expiration"]
  pe -->|"publish"| sns["SNS notifications"]
  sns --> qin["SQS in-app-notifications"]
  sns --> qem["SQS email-notifications"]
  qin --> inapp["Lambda<br/>in_app_notification"]
  qem --> mail["Lambda<br/>send_email"]
  inapp --> ddbn[("DynamoDB<br/>notifications")]
  inapp -->|"query by user_id"| ddbc[("DynamoDB<br/>connections")]
  inapp -->|"PostToConnection"| wsapi["WebSocket API"]
  mail -->|"AdminGetUser: email"| cog["Cognito"]
  mail --> ses["SES"]
```

## WebSocket connection

![WebSocket notifications](../diagrams/Uniflow%20AWS%20Diagram%20WebSocket.jpg)

The token travels in the `token` query string and is checked by a Lambda REQUEST authorizer. Connections are stored with a TTL attribute and looked up by `user_id` when a notification is pushed.

```mermaid
sequenceDiagram
  participant B as Browser
  participant W as WebSocket API
  participant A as ws_authorizer Lambda
  participant C as ws_connect Lambda
  participant D as ws_disconnect Lambda
  participant T as DynamoDB connections
  participant I as in_app_notification Lambda

  B->>W: connect (?token=...)
  W->>A: authorize
  A-->>W: allow / deny
  W->>C: $connect
  C->>T: put connection
  I->>T: query by user_id
  I->>W: PostToConnection
  W-->>B: notification
  B->>W: disconnect
  W->>D: $disconnect
  D->>T: delete connection
```
