output "function_names" {
  description = "Deployed Lambda function names, keyed by role in the notifications flow"
  value       = { for k, f in aws_lambda_function.this : k => f.function_name }
}

output "rest_routes" {
  description = "Routes added to the platform HTTP API"
  value       = values(local.rest_routes)
}

output "websocket_url" {
  description = "Value for the SPA's VITE_NOTIFICATIONS_WEB_APP_URL"
  value       = "wss://${local.ws_api_id}.execute-api.${var.aws_region}.amazonaws.com/prod"
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN repo variable in GitHub Actions"
  value       = aws_iam_role.github_actions.arn
}
