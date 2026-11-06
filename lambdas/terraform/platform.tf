# --- Platform contract: values published by the root stack (`terraform/`) as
# /<project>/<name> SSM parameters. This stack never reads the root's state.
# Apply the root stack first. ---

locals {
  ssm_names = [
    "cognito_user_pool_id",
    "cognito_user_pool_arn",
    "cognito_client_id",
    "http_api_id",
    "http_api_execution_arn",
    "http_api_authorizer_id",
    "websocket_api_id",
    "websocket_api_execution_arn",
    "websocket_management_endpoint",
    "sns_topic_arn",
    "expirations_queue_arn",
    "in_app_queue_arn",
    "email_queue_arn",
    "dynamodb_notifications_name",
    "dynamodb_notifications_arn",
    "dynamodb_connections_name",
    "dynamodb_connections_arn",
    "kms_key_arn",
  ]
}

data "aws_ssm_parameter" "platform" {
  for_each = toset(local.ssm_names)
  name     = "/${var.project-tag}/${each.key}"
}

locals {
  # None of these are secrets (ARNs, ids, names), so unwrap the data source's sensitive flag.
  platform = { for k, p in data.aws_ssm_parameter.platform : k => nonsensitive(p.value) }

  account_id = data.aws_caller_identity.current.account_id
}
