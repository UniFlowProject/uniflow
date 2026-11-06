# Routes on the platform's APIs: REST on the existing HTTP API (Cognito JWT authorizer
# defined in api.tf) and the push channel on the WebSocket API.

# --- HTTP API: /api/notifications/v2/* -> Lambda proxy (payload 2.0) ---

locals {
  http_api_id            = aws_apigatewayv2_api.http.id
  http_authorizer_id     = aws_apigatewayv2_authorizer.cognito.id
  http_api_execution_arn = aws_apigatewayv2_api.http.execution_arn

  # Same paths the SPA already calls (the userId segment must equal the token's sub).
  rest_routes = {
    api_list         = "GET /api/notifications/v2/user/{userId}"
    api_unread_count = "GET /api/notifications/v2/user/{userId}/unread-count"
    api_create       = "POST /api/notifications/v2/notifications"
    api_mark_read    = "PUT /api/notifications/v2/notifications/{id}/mark-read"
    api_delete       = "DELETE /api/notifications/v2/notifications/{id}"
  }
}

resource "aws_apigatewayv2_integration" "rest" {
  for_each = local.rest_routes

  api_id                 = local.http_api_id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.this[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "rest" {
  for_each = local.rest_routes

  api_id             = local.http_api_id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.rest[each.key].id}"
  authorization_type = "JWT"
  authorizer_id      = local.http_authorizer_id
}

resource "aws_lambda_permission" "rest" {
  for_each = local.rest_routes

  statement_id  = "AllowHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  # arn:...:api-id/<stage>/<METHOD>/<path>; path parameters become wildcards.
  source_arn = "${local.http_api_execution_arn}/*/${split(" ", each.value)[0]}${replace(split(" ", each.value)[1], "/\\{[^}]+\\}/", "*")}"
}

# --- WebSocket API: $connect (Lambda authorizer) and $disconnect ---

locals {
  ws_api_id            = aws_apigatewayv2_api.websocket.id
  ws_api_execution_arn = aws_apigatewayv2_api.websocket.execution_arn
}

resource "aws_apigatewayv2_authorizer" "ws" {
  api_id           = local.ws_api_id
  name             = "cognito-token"
  authorizer_type  = "REQUEST"
  authorizer_uri   = aws_lambda_function.this["ws_authorizer"].invoke_arn
  identity_sources = ["route.request.querystring.token"]
}

resource "aws_lambda_permission" "ws_authorizer" {
  statement_id  = "AllowWebSocketAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this["ws_authorizer"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${local.ws_api_execution_arn}/authorizers/${aws_apigatewayv2_authorizer.ws.id}"
}

locals {
  ws_routes = {
    ws_connect    = "$connect"
    ws_disconnect = "$disconnect"
  }
}

resource "aws_apigatewayv2_integration" "ws" {
  for_each = local.ws_routes

  api_id             = local.ws_api_id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = aws_lambda_function.this[each.key].invoke_arn
}

resource "aws_apigatewayv2_route" "ws" {
  for_each = local.ws_routes

  api_id             = local.ws_api_id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.ws[each.key].id}"
  authorization_type = each.key == "ws_connect" ? "CUSTOM" : "NONE"
  authorizer_id      = each.key == "ws_connect" ? aws_apigatewayv2_authorizer.ws.id : null
}

resource "aws_lambda_permission" "ws" {
  for_each = local.ws_routes

  statement_id  = "AllowWebSocketApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${local.ws_api_execution_arn}/*/${each.value}"
}
