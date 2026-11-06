# UniFlow platform: architecture notes

Status: **discussion notes, nothing here is decided unless marked as such.**
Date: 2026-10-23.
Scope: Terraform audit, database strategy, service boundaries, and a possible AI service.

Cost figures are rough, from memory, assuming us-east-1. Verify them with the
AWS pricing calculator and with the real `terraform.tfvars` (it was not read
during the audit).

---

## 1. Terraform audit (`terraform/`)

`terraform fmt -check` and `terraform validate` pass. No plan or apply was run.
A backup of the pre-change directory was taken before editing.

### Changes already applied (no effect on the plan)

- ACM certificate, validation and alias records moved from `edge.tf` to `dns.tf`.
- DynamoDB tables moved from `database.tf` to a new `dynamodb.tf`.
- ECS cluster and cluster locals moved to a new `ecs.tf`.
- `alb_ecs.tf` renamed to `alb.tf`.
- Header comment added to every `.tf` file.
- `description` added to the 21 outputs that lacked one.
- `README.md` file table updated.

Resource addresses are unchanged, so no `moved` blocks were needed.

### Findings

No critical findings. Baseline is sound: RDS encrypted with KMS and not public,
S3 public access blocked with OAC, KMS key rotation on, SQS/SNS encrypted,
insecure-transport deny policies in place.

| Priority | Finding | Location |
|---|---|---|
| High | State is local; remote S3 backend is commented out. No lock, no backup. `backend.hcl.example` exists. | `backend.tf` |
| High | `required_version` pinned to an exact version. Use `~> 1.15`. | `versions.tf:2` |
| High | Fixed `final_snapshot_identifier`; a second destroy/recreate collides with the old snapshot. | `database.tf:62-63` |
| High | No deletion protection on the ALB or the DynamoDB tables; `connections` has no PITR. | `alb.tf:36`, `dynamodb.tf` |
| Medium | KMS key policy statement uses `principals AWS = "*"`, limited only by `CallerAccount` and `ViaService`. | `security.tf:80-83` |
| Medium | SNS may use the CMK with `Resource *` and only a `SourceAccount` condition; add `aws:SourceArn`. | `security.tf:15-29` |
| Medium | Monitoring is thin: only DLQ alarms. No RDS, ALB 5xx or API Gateway 5xx alarms. No `force_ssl` parameter group, no Performance Insights. | `observability.tf`, `database.tf` |
| Medium | No CloudFront or S3 access logging. Default CloudFront certificate cannot enforce TLS 1.2. | `edge.tf` |
| Medium | HTTP API has no throttling or access-log settings on the default stage. | `api.tf` |
| Medium | One NAT gateway for four private subnets (single point of failure per AZ). Subnet CIDRs hardcoded, not derived from `var.vpc_cidr`. No VPC endpoints, no flow logs. | `network.tf` |
| Low | `project-tag` uses a hyphen; every other variable is `snake_case`. | `variables.tf:1` |
| Low | No variable has `validation`. | `variables.tf` |
| Low | `projects = var.project-tag` repeated on resources despite provider `default_tags`. | many |
| Low | `*.tfplan` and the state lock info file are not in `.gitignore`. | `.gitignore` |

### Proposed order of work

1. Enable the S3 backend and migrate state (`init -migrate-state`).
2. `required_version = "~> 1.15"`.
3. Deletion protection on the ALB and DynamoDB tables, PITR on `connections`.
4. Then the changes that add resources or alter policies (alarms, RDS parameter
   group, KMS policy tightening, VPC endpoints). The parameter group can reboot RDS.

---

## 2. Database strategy

### Current state

- `uniflow-academic-service` is Java / Spring Boot with JPA and Flyway.
- It currently targets **SQL Server** (`application.yml`, `pom.xml`); the
  Postgres driver and Flyway block are commented out. Terraform provisions
  **Postgres 16** on RDS. The SQL Server to Postgres migration is half done.
- Tables (schema `academic`): `students`, `periods`, `subjects`.
  - `students` is the user table (id is the Google sub).
  - `periods` and `subjects` carry a logical `student_id`. One FK exists:
    `subjects.period_id` to `periods.id` with `ON DELETE CASCADE`.
  - Unique: `uk_subject_period_code` on (`student_id`, `period_id`, `code`).
- Everything is filtered by `student_id`. No SQL joins or aggregations;
  statistics are computed in Java after loading rows.
- The only multi-write invariant: one active period per student
  (`ActivatePeriodService`).
- Verdict: the data is key-value shaped. Relational features are barely used.

### What Cognito makes redundant

- The whole `students` table (name, email, avatar come from Cognito claims).
- `RegisterStudentService`, `AuthController`, `GoogleTokenValidator`,
  `JwtProvider`, `JwtAuthenticationFilter`. The API Gateway Cognito authorizer
  authenticates already.
- What stays: academic data keyed by the Cognito `sub`.

### Cost comparison (approximate, monthly)

| Item | Current default (Multi-AZ) | Postgres Single-AZ | DynamoDB on-demand |
|---|---|---|---|
| `db.t4g.micro` | ~$23 | ~$12 | n/a |
| Storage (20 GiB gp3) | ~$4.6 | ~$2.3 | cents |
| Secrets Manager, logs | ~$1-2 | ~$1-2 | n/a |
| **Total** | **~$30** | **~$15** | **~$1 or less** |

Multi-AZ is the default and roughly doubles instance cost (`variables.tf:101-105`).
Removing RDS does not remove the NAT gateway (~$32/month plus traffic), which
costs more than RDS. If services only talk to DynamoDB, SQS and SNS, VPC
endpoints (S3 and DynamoDB gateway endpoints are free) might allow dropping
the NAT. Needs a check of what else leaves via the internet.

### Leaning (not decided)

Move academic data to DynamoDB and retire RDS.

- Key design: single table, PK `userId`, SK `PERIOD#id` and `SUBJECT#periodId#id`.
- `LIKE` search becomes an in-memory filter (few subjects per user).
- Cascade delete becomes query + batch delete.
- Active-period invariant and unique subject code use `TransactWriteItems`.
- Cost of the move: rewrite the persistence adapters, validate in code instead
  of CHECK constraints, remap existing `student_id` values (Google sub) to
  Cognito `sub` if there is real data.
- Keep Postgres only if reports with joins across periods, subjects and tasks
  are expected. If kept: Single-AZ and drop the `postgresql`/`upgrade` log exports.

Open question: is there real data in the current database, or only test data?
Without real data the migration is much cheaper.

Side note: `StudentEntity` declares `provider` / `provider_id` columns and a
unique constraint that do not exist in migration V3; with `ddl-auto: validate`
this may fail. It disappears if `students` goes away.

---

## 3. Tasks in the academic service

Tasks now live in `uniflow-academic-service` (package `com.uniflow.academic.task`)
and are stored in its PostgreSQL database. The Python `uniflow-tasks-service` and
its DynamoDB table are no longer part of the platform, so no tasks table or tasks
ECS role is needed in Terraform.

- The HTTP API is `/tasks` in academic (CRUD, `GET /tasks/stats`,
  `PATCH /tasks/{id}/status`, filters and pagination on the list endpoint).
- `subjectId` was renamed to `courseId`; tasks also reference a `periodId`.
- Tasks, courses and periods share one database, so these references are
  resolved inside the service instead of across services.

---

## 4. Service boundaries

Current services: `uniflow-academic-service` (Java/Spring Boot, includes tasks),
notifications (separate, language not checked).

### Merge academic and tasks?

Done: tasks were merged into academic (Spring Boot, PostgreSQL). The original
reasoning, kept for context, was to use **one service in one language**:

- The domain is one chain (period, subject, task); merging removes orphan
  references, delete cascades by events, and ID-format coupling.
- One developer; each extra service adds a Fargate task, target group, IAM role,
  pipeline and variables. Academic is not even attached to the ALB yet.
- Academic needs its persistence layer rewritten and its auth module removed
  anyway; what remains is CRUD for two entities plus in-memory statistics.

Language: Java/Spring Boot was chosen; the tasks logic was reimplemented in academic.

Keep notifications separate: asynchronous, own WebSocket, several consumers.

### If three services are required

Planning (periods, subjects, tasks) + notifications + a third. Candidates:

1. **AI study assistant**: isolated by cost, latency and failure mode. Chosen direction.
2. Calendar / integrations (iCal, Google Calendar): real isolation from external APIs.
3. Grades and evaluations: new domain, but the most coupled and smallest; better as a module.
4. User profile/preferences: too small to be a service.

---

## 5. Grades (parked, would be a module of the planning service)

- Tasks are things to hand in by a date; grades are what an evaluation is
  **worth** and what score was obtained. Keep them separate concepts.
- Grading scheme per subject: weighted components, scale (configurable),
  passing mark.
- Evaluation: name, category, weight, max score, date, nullable score.
  Optional `task_id` link for graded deliverables; completing a task does not set a grade.
- Calculations: current average over graded items (normalised by the weights
  counted so far), projected average, score needed to pass or hit a target,
  period GPA weighted by credits. Validate weights sum to 100.
- Storage: PK `userId`, SK `SCHEME#subjectId` and `EVAL#subjectId#evalId`.
- Needs a cleanup event when a subject is deleted.

---

## 6. AI service (direction of interest)

### Features, by value over effort

1. **Syllabus import**: upload a PDF or photo, extract professor, credits,
   schedule, exam and delivery dates, evaluation weights as validated JSON,
   with a review screen before saving. Removes the manual data entry of a semester.
2. **Task breakdown**: split a task into dated subtasks.
3. **Weekly study plan** from pending tasks, exam dates and workload.
4. **Chat with context** ("what do I have this week?"). Needs access to other
   services' data; do it last.

Start with 1 and 2: cheap, single-shot, easy to verify.

### Architecture

- Mostly stateless service (Python / FastAPI, or Lambda).
- Long jobs async: respond with a `job_id`, work goes through SQS, result and
  status stored in DynamoDB, completion pushed through the existing
  notifications WebSocket.
- Read user data through the planning service's API forwarding the user's JWT,
  not by reading its tables.
- **The AI proposes, never writes**: output is a validated proposal; the
  frontend confirms it against the planning service.
- Provider: Bedrock fits IAM and Terraform (no keys to store); the Anthropic or
  Gemini APIs are more direct and often get new models first. Undecided.

### Risks to settle up front

- **Cost control**: per-user and per-day limits and a usage table.
- **Prompt injection** via uploaded documents: only structured output validated
  against a schema, never actions executed by the model.
- **Privacy**: academic documents are personal data; decide retention and
  check the provider's retention terms.
- **Failures**: timeouts, retries, clear user-facing errors. This service will fail more than the others.

---

## 7. Open questions

1. Is there real data in the academic database, or only test data?
2. ~~Merge academic and tasks?~~ Tasks now live in academic (Spring Boot, PostgreSQL).
3. Do tasks die with their course, or survive without one?
4. Is Spring Boot a goal in itself?
5. AI provider: Bedrock or a direct API?
6. Can the NAT gateway be removed with VPC endpoints?
7. Start with the Terraform hardening (backend, version pin, deletion protection)?

## 8. Suggested next steps

1. Terraform: backend, `required_version`, deletion protection (no resource recreation).
2. Decide the database and service-merge questions above.
3. Define a single `user_id` (Cognito `sub`) across services.
4. ~~Add the tasks table and its ECS task role to Terraform.~~ Not needed: tasks live in academic/Postgres.
5. Design the syllabus-import flow end to end (JSON schema, validation, confirmation).
