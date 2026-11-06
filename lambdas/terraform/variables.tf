variable "project-tag" {
  type        = string
  description = "The tag to use for the project (prefix of the platform SSM parameters)"
  default     = "uniflow"
}

variable "aws_region" {
  type        = string
  description = "AWS region (must match the platform stack)"
  default     = "us-east-1"
}

variable "lambda_runtime" {
  type        = string
  description = "Lambda runtime for every function (the AWS SDK v3 is provided by the runtime)"
  default     = "nodejs22.x"
}

variable "log_retention_days" {
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

variable "ses_sender_email" {
  type        = string
  description = "Verified SES sender identity used as FROM_EMAIL. Use the same value as the root stack's ses_sender_email (which creates the identity). null disables the e-mail sender configuration."
  default     = null
}

variable "default_to_email" {
  type        = string
  description = "Fallback recipient when the Cognito e-mail lookup fails. Required while SES is in sandbox mode (recipients must be verified); null = no fallback."
  default     = null
}

variable "email_timezone" {
  type        = string
  description = "IANA timezone used to format deadlines in e-mails"
  default     = "America/Costa_Rica"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo allowed to assume the CI deploy role via OIDC (main branch only), as org/repo"
  default     = "UniFlowProject/uniflow-lambdas"

  validation {
    condition     = !can(regex("[*?]", var.github_repo))
    error_message = "github_repo must not contain wildcards (* or ?) — the OIDC trust condition uses StringEquals and expects an exact org/repo."
  }
}
