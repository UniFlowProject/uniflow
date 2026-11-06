# API Gateway: HTTP API (Cognito JWT -> VPC Link -> Cloud Map -> ECS tasks) and the WebSocket API shell.

# --- HTTP API (REST traffic -> Cloud Map services via VPC Link) ---

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.project-tag}-http-api"
  protocol_type = "HTTP"

  # No cors_configuration: in production the SPA reaches this API same-origin
  # through the CloudFront /api/* behavior (edge.tf); the services handle CORS
  # for direct calls such as local development.

  tags = {
    Name     = "${var.project-tag}-http-api"
    projects = var.project-tag
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.spa.id]
    issuer   = local.cognito_issuer_uri
  }
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.project-tag}-vpc-link-sg"
  description = "API Gateway VPC Link ENIs"
  vpc_id      = aws_vpc.uniflow_vpc.id

  tags = {
    Name     = "${var.project-tag}-vpc-link-sg"
    projects = var.project-tag
  }
}

# Targets are service tasks inside the VPC; each service stack opens its own
# port to this security group.
resource "aws_vpc_security_group_egress_rule" "vpc_link_to_vpc" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Traffic to service tasks inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project-tag}-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = [for s in aws_subnet.private_app : s.id]

  tags = {
    Name     = "${var.project-tag}-vpc-link"
    projects = var.project-tag
  }
}

# Private integration through AWS Cloud Map: API Gateway resolves the healthy
# instances registered by the ECS service, so no load balancer is needed.
# Same contract as docker/floci/init.sh: the /api/academic/v2 prefix is
# stripped and the service receives /<proxy>.
resource "aws_apigatewayv2_integration" "academic" {
  api_id             = aws_apigatewayv2_api.http.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_service_discovery_service.academic.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id

  request_parameters = {
    "overwrite:path" = "/$request.path.proxy"
  }
}

resource "aws_apigatewayv2_integration" "academic_health" {
  api_id             = aws_apigatewayv2_api.http.id
  integration_type   = "HTTP_PROXY"
  integration_method = "GET"
  integration_uri    = aws_service_discovery_service.academic.arn
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id

  request_parameters = {
    "overwrite:path" = "/health"
  }
}

resource "aws_apigatewayv2_route" "academic_health" {
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = "GET /api/academic/health"
  target             = "integrations/${aws_apigatewayv2_integration.academic_health.id}"
  authorization_type = "NONE"
}

resource "aws_apigatewayv2_route" "academic" {
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = "ANY /api/academic/v2/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.academic.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "http_default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = {
    projects = var.project-tag
  }
}

# --- WebSocket API shell (routes/integrations/authorizer owned by lambdas repo) ---

resource "aws_apigatewayv2_api" "websocket" {
  name                       = "${var.project-tag}-websocket-api"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  tags = {
    Name     = "${var.project-tag}-websocket-api"
    projects = var.project-tag
  }
}

resource "aws_apigatewayv2_stage" "websocket" {
  api_id      = aws_apigatewayv2_api.websocket.id
  name        = "prod"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId    = "$context.requestId"
      ip           = "$context.identity.sourceIp"
      requestTime  = "$context.requestTime"
      routeKey     = "$context.routeKey"
      status       = "$context.status"
      eventType    = "$context.eventType"
      connectionId = "$context.connectionId"
    })
  }

  tags = {
    projects = var.project-tag
  }
}
