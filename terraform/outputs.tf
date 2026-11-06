# Stack outputs.

output "vpc_id" {
  description = "ID of the shared VPC"
  value       = aws_vpc.uniflow_vpc.id
}

output "spa_bucket_name" {
  description = "Upload the built SPA here"
  value       = aws_s3_bucket.spa.bucket
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (use for cache invalidations)"
  value       = aws_cloudfront_distribution.spa.id
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.spa.domain_name
}

output "route53_zone_id" {
  description = "ID of the existing hosted zone used for the custom domain (null without a custom domain)"
  value       = local.site_zone_id
}

output "route53_name_servers" {
  description = "Name servers of the existing zone (must match the delegation at the registrar)"
  value       = local.custom_domain ? data.aws_route53_zone.site[0].name_servers : null
}

output "site_url" {
  description = "Public URL of the SPA"
  value       = local.site_url
}

output "http_api_id" {
  description = "HTTP API ID"
  value       = aws_apigatewayv2_api.http.id
}

output "http_api_execution_arn" {
  description = "HTTP API execution ARN (for Lambda permissions)"
  value       = aws_apigatewayv2_api.http.execution_arn
}

output "http_api_authorizer_id" {
  description = "ID of the Cognito JWT authorizer on the HTTP API"
  value       = aws_apigatewayv2_authorizer.cognito.id
}

output "websocket_api_id" {
  description = "WebSocket API ID"
  value       = aws_apigatewayv2_api.websocket.id
}

output "websocket_api_execution_arn" {
  description = "WebSocket API execution ARN (for Lambda permissions)"
  value       = aws_apigatewayv2_api.websocket.execution_arn
}

output "websocket_management_endpoint" {
  description = "WebSocket @connections management endpoint"
  value       = local.ssm_strings.websocket_management_endpoint
}

output "api_endpoint" {
  description = "Invoke URL of the HTTP API (the SPA calls <this>/api/academic/v2)"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "cloudmap_academic_service_arn" {
  description = "Cloud Map service the academic ECS service registers into"
  value       = aws_service_discovery_service.academic.arn
}

output "vpc_link_sg_id" {
  description = "Security group of the API Gateway VPC link (allowed source for service security groups)"
  value       = aws_security_group.vpc_link.id
}

output "cognito_issuer_uri" {
  description = "Cognito issuer URI (iss claim) for the JWT authorizer and the services"
  value       = local.cognito_issuer_uri
}

output "cognito_hosted_ui_url" {
  description = "Cognito Hosted UI base URL (null when cognito_domain_prefix is not set)"
  value       = var.cognito_domain_prefix != null ? "https://${var.cognito_domain_prefix}.auth.${data.aws_region.current.region}.amazoncognito.com" : null
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master credentials"
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID"
  value       = aws_cognito_user_pool.this.id
}

output "cognito_client_id" {
  description = "Cognito SPA app client ID"
  value       = aws_cognito_user_pool_client.spa.id
}

output "sns_topic_arn" {
  description = "ARN of the notifications SNS topic"
  value       = aws_sns_topic.notifications.arn
}

output "queue_urls" {
  description = "SQS queue URLs keyed by queue name"
  value       = { for k, q in aws_sqs_queue.this : k => q.url }
}

output "queue_arns" {
  description = "SQS queue ARNs keyed by queue name"
  value       = { for k, q in aws_sqs_queue.this : k => q.arn }
}

output "scheduler_group_name" {
  description = "EventBridge Scheduler group name"
  value       = aws_scheduler_schedule_group.this.name
}

output "scheduler_role_arn" {
  description = "ARN of the role EventBridge Scheduler assumes to send to the expirations queue"
  value       = aws_iam_role.scheduler.arn
}

output "kms_key_arn" {
  description = "ARN of the shared KMS CMK"
  value       = aws_kms_key.shared.arn
}

output "ssm_parameter_names" {
  description = "All published /<project>/<name> contract parameters"
  value       = sort([for p in aws_ssm_parameter.contract : p.name])
}
