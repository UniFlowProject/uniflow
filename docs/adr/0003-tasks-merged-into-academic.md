# 0003. Merge tasks into the academic service

- Status: Accepted
- Date: 2026-11

## Context

Tasks were a separate Python (FastAPI) service with its own DynamoDB table, while periods and courses lived in the Java academic service. The domain is one chain: user, period, course, task.

## Decision

Tasks live in `uniflow-academic-service` (package `com.uniflow.academic.task`, same hexagonal layout as `period` and `course`) and are stored in its PostgreSQL database. `uniflow-tasks-service` is archived.

- API: `/tasks` with CRUD, `GET /tasks/stats`, `PATCH /tasks/{id}/status`, and filters plus pagination on the list endpoint.
- `subjectId` became `courseId`; tasks also reference a `periodId`.
- Reminders are created by the academic service in EventBridge Scheduler (`REMINDER_SCHEDULER=eventbridge`) and delivered to the `expirations` queue consumed by a Lambda (see ADR 0002).

Rationale recorded in the archived tasks repo README: keeping tasks next to courses removed a network hop and a separate deployment. The earlier design notes add that references between period, course and task are resolved inside one service and database, instead of through events and ID-format coupling across services, and that each extra service costs a Fargate task, target group, IAM role, pipeline and variables for a one-developer project.

## Consequences

- One deployable and one database for the planning domain; no orphan references across services.
- The Terraform stack needs no tasks table or tasks ECS role.
- The academic service now also depends on EventBridge Scheduler; reminders are best effort (scheduled after the database commit, no retry or outbox), as documented in its README.
- Open question from the design notes, not decided here: whether tasks should survive without a course.
