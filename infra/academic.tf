# Academic service: ECR repository, log group, security groups, IAM roles, Fargate task definition and the ECS service registered in the internal ALB target group.

locals {
  # Demo network: tasks run in the public subnets with a public IP (no NAT
  # gateway). They are still unreachable from the internet: the security group
  # only admits the internal ALB.
  service_subnet_ids = [for s in aws_subnet.public : s.id]
}

# --- ECR ---

resource "aws_ecr_repository" "academic" {
  name                 = "${var.project-tag}/academic-service"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Logs ---

resource "aws_cloudwatch_log_group" "academic" {
  name              = "/ecs/${var.project-tag}-academic-service"
  retention_in_days = var.log_retention_days
}

# --- Security group: the app port is open only to the internal ALB. ---

resource "aws_security_group" "academic_service" {
  name        = "${var.project-tag}-academic-service-sg"
  description = "Academic service Fargate tasks"
  vpc_id      = aws_vpc.uniflow_vpc.id
}

resource "aws_vpc_security_group_ingress_rule" "academic_from_alb" {
  security_group_id            = aws_security_group.academic_service.id
  description                  = "App port from the internal ALB"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
}

resource "aws_vpc_security_group_egress_rule" "academic_all" {
  security_group_id = aws_security_group.academic_service.id
  description       = "ECR, Secrets Manager, EventBridge Scheduler and the database"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# The RDS security group admits the private-app subnets only; the tasks live in
# the public subnets, so admit this service's security group.
resource "aws_vpc_security_group_ingress_rule" "rds_from_academic" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from the academic service"
  referenced_security_group_id = aws_security_group.academic_service.id
  ip_protocol                  = "tcp"
  from_port                    = aws_db_instance.postgres.port
  to_port                      = aws_db_instance.postgres.port
}

# --- IAM: task execution role (ECR pull + logs) and task role (runtime
# permissions of the app, see the reminder policy below). ---

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "academic_execution" {
  name               = "${var.project-tag}-academic-service-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "academic_execution" {
  role       = aws_iam_role.academic_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The execution role injects the database credentials from the RDS-managed secret.
data "aws_iam_policy_document" "academic_read_db_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.postgres.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "academic_execution_db_secret" {
  name   = "read-db-secret"
  role   = aws_iam_role.academic_execution.id
  policy = data.aws_iam_policy_document.academic_read_db_secret.json
}

resource "aws_iam_role" "academic_task" {
  name               = "${var.project-tag}-academic-service-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

# Task role: manage reminder schedules in the scheduler group and pass the
# scheduler role (only needed when reminder_scheduler = "eventbridge").
data "aws_iam_policy_document" "academic_task_reminders" {
  statement {
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:UpdateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:GetSchedule",
    ]
    resources = ["arn:aws:scheduler:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:schedule/${aws_scheduler_schedule_group.this.name}/*"]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.scheduler.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "academic_task_reminders" {
  count  = var.reminder_scheduler == "eventbridge" ? 1 : 0
  name   = "reminder-schedules"
  role   = aws_iam_role.academic_task.id
  policy = data.aws_iam_policy_document.academic_task_reminders.json
}

# --- Task definition ---

resource "aws_ecs_task_definition" "academic" {
  family                   = "${var.project-tag}-academic-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.academic_execution.arn
  task_role_arn            = aws_iam_role.academic_task.arn

  container_definitions = jsonencode([
    {
      name      = "academic-service"
      image     = "${aws_ecr_repository.academic.repository_url}:${var.image_tag}"
      essential = true

      environment = [
        { name = "SERVER_PORT", value = tostring(var.container_port) },
        { name = "DB_HOST", value = aws_db_instance.postgres.address },
        { name = "DB_PORT", value = tostring(aws_db_instance.postgres.port) },
        { name = "DB_NAME", value = aws_db_instance.postgres.db_name },
        { name = "COGNITO_ISSUER_URI", value = local.cognito_issuer_uri },
        { name = "COGNITO_ALLOWED_CLIENT_IDS", value = aws_cognito_user_pool_client.spa.id },
        { name = "CORS_ALLOWED_ORIGINS", value = local.site_url },
        { name = "REMINDER_SCHEDULER", value = var.reminder_scheduler },
        { name = "REMINDER_GROUP_NAME", value = aws_scheduler_schedule_group.this.name },
        { name = "REMINDER_QUEUE_ARN", value = aws_sqs_queue.this["expirations"].arn },
        { name = "REMINDER_ROLE_ARN", value = aws_iam_role.scheduler.arn },
      ]

      # RDS-managed secret is a JSON document: {"username": ..., "password": ...}
      secrets = [
        { name = "DB_USER", valueFrom = "${aws_db_instance.postgres.master_user_secret[0].secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${aws_db_instance.postgres.master_user_secret[0].secret_arn}:password::" },
      ]

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.academic.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "academic-service"
        }
      }
    }
  ])
}

# --- Service ---

resource "aws_ecs_service" "academic" {
  name            = "${var.project-tag}-academic-service"
  cluster         = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.academic.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = local.service_subnet_ids
    security_groups  = [aws_security_group.academic_service.id]
    assign_public_ip = true
  }

  # Spring Boot needs about 60s to start; ignore failing ALB health checks meanwhile.
  health_check_grace_period_seconds = 90

  # Registers the task IP in the internal ALB target group; the HTTP API reaches
  # the ALB through the VPC link.
  load_balancer {
    target_group_arn = aws_lb_target_group.academic.arn
    container_name   = "academic-service"
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener_rule.academic]
}
