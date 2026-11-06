# SSM parameter contract published for consumer repos.

# Cross-repo contract: service/lambda repos read these with
# data "aws_ssm_parameter" instead of coupling to this stack's remote state.
# Lists are published as StringList (comma-separated).
locals {
  ssm_strings = {
    vpc_id                        = aws_vpc.uniflow_vpc.id
    ecs_cluster_name              = local.ecs_cluster_name
    ecs_cluster_arn               = local.ecs_cluster_arn
    vpc_link_sg_id                = aws_security_group.vpc_link.id
    cloudmap_namespace_id         = aws_service_discovery_private_dns_namespace.this.id
    cloudmap_academic_service_arn = aws_service_discovery_service.academic.arn
    cloudmap_academic_service_id  = aws_service_discovery_service.academic.id
    rds_endpoint                  = aws_db_instance.postgres.endpoint
    rds_address                   = aws_db_instance.postgres.address
    rds_port                      = tostring(aws_db_instance.postgres.port)
    rds_db_name                   = aws_db_instance.postgres.db_name
    rds_secret_arn                = aws_db_instance.postgres.master_user_secret[0].secret_arn
    rds_sg_id                     = aws_security_group.rds.id
    cognito_user_pool_id          = aws_cognito_user_pool.this.id
    cognito_user_pool_arn         = aws_cognito_user_pool.this.arn
    cognito_client_id             = aws_cognito_user_pool_client.spa.id
    cognito_issuer_uri            = local.cognito_issuer_uri
    site_url                      = local.site_url
    http_api_id                   = aws_apigatewayv2_api.http.id
    http_api_execution_arn        = aws_apigatewayv2_api.http.execution_arn
    http_api_authorizer_id        = aws_apigatewayv2_authorizer.cognito.id
    websocket_api_id              = aws_apigatewayv2_api.websocket.id
    websocket_api_execution_arn   = aws_apigatewayv2_api.websocket.execution_arn
    websocket_management_endpoint = "https://${aws_apigatewayv2_api.websocket.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/${aws_apigatewayv2_stage.websocket.name}"
    sns_topic_arn                 = aws_sns_topic.notifications.arn
    expirations_queue_url         = aws_sqs_queue.this["expirations"].url
    expirations_queue_arn         = aws_sqs_queue.this["expirations"].arn
    in_app_queue_url              = aws_sqs_queue.this["in-app-notifications"].url
    in_app_queue_arn              = aws_sqs_queue.this["in-app-notifications"].arn
    email_queue_url               = aws_sqs_queue.this["email-notifications"].url
    email_queue_arn               = aws_sqs_queue.this["email-notifications"].arn
    scheduler_group_name          = aws_scheduler_schedule_group.this.name
    scheduler_role_arn            = aws_iam_role.scheduler.arn
    dynamodb_notifications_name   = aws_dynamodb_table.notifications.name
    dynamodb_notifications_arn    = aws_dynamodb_table.notifications.arn
    dynamodb_connections_name     = aws_dynamodb_table.connections.name
    dynamodb_connections_arn      = aws_dynamodb_table.connections.arn
    kms_key_arn                   = aws_kms_key.shared.arn
    spa_bucket_name               = aws_s3_bucket.spa.bucket
    cloudfront_distribution_id    = aws_cloudfront_distribution.spa.id
    cloudfront_domain             = aws_cloudfront_distribution.spa.domain_name
    api_access_log_group_name     = aws_cloudwatch_log_group.api_access.name
    alarm_topic_arn               = aws_sns_topic.alarms.arn
  }

  ssm_lists = {
    public_subnet_ids       = [for s in aws_subnet.public : s.id]
    private_app_subnet_ids  = [for s in aws_subnet.private_app : s.id]
    private_data_subnet_ids = [for s in aws_subnet.private_data : s.id]
  }

  ssm_parameters = merge(
    { for k, v in local.ssm_strings : k => { type = "String", value = v } },
    { for k, v in local.ssm_lists : k => { type = "StringList", value = join(",", v) } },
  )
}

resource "aws_ssm_parameter" "contract" {
  for_each = local.ssm_parameters

  name  = "/${var.project-tag}/${each.key}"
  type  = each.value.type
  value = each.value.value

  tags = {
    projects = var.project-tag
  }
}
