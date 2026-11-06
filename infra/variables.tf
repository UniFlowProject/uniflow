# Input variables, grouped by domain.

variable "project-tag" {
  type        = string
  description = "The tag to use for the project"
  default     = "uniflow"
}

variable "aws_region" {
  type        = string
  description = "AWS region for the stack"
  default     = "us-east-1"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

# --- Edge ---

variable "domain_name" {
  type        = string
  description = "Custom domain for CloudFront (null = use the *.cloudfront.net domain)"
  default     = null
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 hosted zone ID for domain_name (required when domain_name is set)"
  default     = null
}

variable "enable_waf" {
  type        = bool
  description = "Attach a WAFv2 web ACL to CloudFront (about 8 USD/month plus per-request; off for the demo)"
  default     = false
}

variable "waf_rate_limit" {
  type        = number
  description = "Max requests per 5 minutes per IP before WAF blocks"
  default     = 2000
}

variable "cloudfront_price_class" {
  type        = string
  description = "CloudFront price class"
  default     = "PriceClass_100"
}

# --- Auth ---

variable "cognito_domain_prefix" {
  type        = string
  description = "Cognito hosted-UI domain prefix (null = no hosted UI domain)"
  default     = null
}

variable "cognito_app_origins" {
  type        = list(string)
  description = "Extra SPA origins for the Cognito app client (the site URL is always added). Callback is <origin>/auth/callback, logout is <origin>."
  default     = ["http://localhost:3000"]
}

variable "cognito_deletion_protection" {
  type        = string
  description = "Cognito user pool deletion protection (ACTIVE or INACTIVE). INACTIVE makes demo teardown possible."
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.cognito_deletion_protection)
    error_message = "cognito_deletion_protection must be ACTIVE or INACTIVE."
  }
}

# --- Network ---

variable "enable_nat_gateway" {
  type        = bool
  description = "Create a single NAT gateway for the private subnets (about 33 USD/month plus data). Off for the demo: Fargate tasks run in the public subnets with a public IP."
  default     = false
}

# --- Compute ---

variable "ecs_container_insights" {
  type        = bool
  description = "Enable ECS Container Insights (extra CloudWatch cost)"
  default     = false
}

# --- Database ---

variable "rds_engine_version" {
  type        = string
  description = "PostgreSQL engine version"
  default     = "16"
}

variable "rds_instance_class" {
  type        = string
  description = "RDS instance class"
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  type        = number
  description = "Initial RDS storage in GiB"
  default     = 20
}

variable "rds_max_allocated_storage" {
  type        = number
  description = "RDS storage autoscaling ceiling in GiB"
  default     = 100
}

variable "rds_multi_az" {
  type        = bool
  description = "Enable RDS Multi-AZ (roughly doubles instance cost; off for the demo)"
  default     = false
}

variable "rds_deletion_protection" {
  type        = bool
  description = "Enable RDS deletion protection"
  default     = true
}

variable "rds_backup_retention_days" {
  type        = number
  description = "Automated backup retention in days"
  default     = 7
}

variable "rds_skip_final_snapshot" {
  type        = bool
  description = "Skip the final snapshot on destroy. The fixed snapshot identifier collides on a second destroy, so set true for throwaway demos."
  default     = false
}

variable "rds_db_name" {
  type        = string
  description = "Initial database name"
  default     = "uniflow"
}

variable "rds_master_username" {
  type        = string
  description = "RDS master username (password is managed in Secrets Manager)"
  default     = "uniflow_admin"
}

# --- Messaging ---

variable "ses_sender_email" {
  type        = string
  description = "SES sender e-mail identity to create; also used as FROM_EMAIL by the e-mail Lambda (null = none)"
  default     = null
}

variable "sqs_max_receive_count" {
  type        = number
  description = "Receives before a message moves to the DLQ"
  default     = 5
}

# --- Security / observability ---

variable "enable_guardduty" {
  type        = bool
  description = "Create a GuardDuty detector (set false if the account already has one)"
  default     = false
}

variable "enable_inspector" {
  type        = bool
  description = "Enable Inspector2 for ECR, EC2 and Lambda"
  default     = false
}

variable "log_retention_days" {
  type        = number
  description = "Retention for shared CloudWatch log groups"
  default     = 14
}

variable "alarm_email" {
  type        = string
  description = "E-mail subscribed to the alarm topic (null = no subscription)"
  default     = null
}

# --- Academic service ---

variable "container_port" {
  type        = number
  description = "Port the Spring Boot app listens on (matches Dockerfile SERVER_PORT and the ALB target group)"
  default     = 3001
}

variable "task_cpu" {
  type        = number
  description = "Fargate task CPU units"
  default     = 512
}

variable "task_memory" {
  type        = number
  description = "Fargate task memory in MiB"
  default     = 1024
}

variable "desired_count" {
  type        = number
  description = "Number of Fargate tasks to run. The first apply has no image in ECR yet, so keep 0, push an image from the academic repo, then set desired_count in terraform.tfvars: any later apply resets the service to this value"
  default     = 0
}

variable "image_tag" {
  type        = string
  description = "ECR image tag deployed by the task definition"
  default     = "latest"
}

variable "reminder_scheduler" {
  type        = string
  description = "Reminder backend: eventbridge (EventBridge Scheduler into the expirations queue) or noop"
  default     = "eventbridge"

  validation {
    condition     = contains(["eventbridge", "noop"], var.reminder_scheduler)
    error_message = "reminder_scheduler must be eventbridge or noop."
  }
}

# --- Lambdas ---

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime for every function (the AWS SDK v3 is provided by the runtime)"
  default     = "nodejs22.x"
}

variable "lambda_log_retention_days" {
  type        = number
  description = "CloudWatch log retention for the Lambda log groups"
  default     = 7
}

variable "sqs_max_concurrency" {
  type        = number
  description = "Maximum concurrent invocations per SQS event source mapping (minimum 2)"
  default     = 2

  validation {
    condition     = var.sqs_max_concurrency >= 2
    error_message = "sqs_max_concurrency must be at least 2 (SQS event source mapping limit)."
  }
}

variable "default_to_email" {
  type        = string
  description = "Fallback recipient when the Cognito e-mail lookup fails. Required while SES is in sandbox mode (recipients must be verified); null = no fallback"
  default     = null
}

variable "email_timezone" {
  type        = string
  description = "IANA timezone used to format deadlines in e-mails"
  default     = "America/Costa_Rica"
}

# --- CI (GitHub Actions OIDC) ---

variable "github_repos" {
  type        = map(string)
  description = "GitHub repos (org/repo) allowed to assume each CI role via OIDC, keyed by role: academic, frontend, lambdas"
  default = {
    academic = "UniFlowProject/uniflow-academic-service"
    frontend = "UniFlowProject/uniflow-frontend"
    lambdas  = "UniFlowProject/uniflow"
  }

  validation {
    condition     = alltrue([for r in values(var.github_repos) : !can(regex("[*?]", r))])
    error_message = "github_repos must not contain wildcards (* or ?): the OIDC trust condition uses StringEquals and expects exact org/repo values."
  }

  validation {
    condition     = alltrue([for k in ["academic", "frontend", "lambdas"] : contains(keys(var.github_repos), k)])
    error_message = "github_repos must define academic, frontend and lambdas."
  }
}

variable "github_frontend_environment" {
  type        = string
  description = "GitHub Actions environment allowed to assume the frontend CI role. A job that declares environment: gets sub=repo:org/repo:environment:<name>, not the ref form"
  default     = "production"
}
