# Least-privilege execution role per function: its own log group plus only the actions it needs.

locals {
  kms_key_arn = aws_kms_key.shared.arn

  # DynamoDB, SQS and SNS use the platform's customer-managed KMS key.
  kms_actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
  sqs_consume = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.functions

  name               = "${var.project-tag}-${replace(each.key, "_", "-")}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

locals {
  notifications_table_arn = aws_dynamodb_table.notifications.arn
  connections_table_arn   = aws_dynamodb_table.connections.arn

  kms_statement = { sid = "Kms", actions = local.kms_actions, resources = [local.kms_key_arn] }

  function_statements = {
    api_create = [
      { sid = "PutNotification", actions = ["dynamodb:PutItem"], resources = [local.notifications_table_arn] },
      local.kms_statement,
    ]
    api_list = [
      { sid = "QueryNotifications", actions = ["dynamodb:Query"], resources = [local.notifications_table_arn] },
      local.kms_statement,
    ]
    api_unread_count = [
      { sid = "QueryNotifications", actions = ["dynamodb:Query"], resources = [local.notifications_table_arn] },
      local.kms_statement,
    ]
    api_mark_read = [
      { sid = "UpdateNotification", actions = ["dynamodb:UpdateItem"], resources = [local.notifications_table_arn] },
      local.kms_statement,
    ]
    api_delete = [
      { sid = "DeleteNotification", actions = ["dynamodb:DeleteItem"], resources = [local.notifications_table_arn] },
      local.kms_statement,
    ]

    process_expiration = [
      { sid = "ConsumeExpirations", actions = local.sqs_consume, resources = [aws_sqs_queue.this["expirations"].arn] },
      { sid = "PublishNotifications", actions = ["sns:Publish"], resources = [aws_sns_topic.notifications.arn] },
      local.kms_statement,
    ]

    send_email = [
      { sid = "ConsumeEmailQueue", actions = local.sqs_consume, resources = [aws_sqs_queue.this["email-notifications"].arn] },
      { sid = "SendEmail", actions = ["ses:SendEmail"], resources = ["arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/*"] },
      { sid = "ResolveRecipient", actions = ["cognito-idp:AdminGetUser"], resources = [aws_cognito_user_pool.this.arn] },
      local.kms_statement,
    ]

    in_app_notification = [
      { sid = "ConsumeInAppQueue", actions = local.sqs_consume, resources = [aws_sqs_queue.this["in-app-notifications"].arn] },
      { sid = "PutNotification", actions = ["dynamodb:PutItem"], resources = [local.notifications_table_arn] },
      { sid = "ReadConnections", actions = ["dynamodb:Query"], resources = ["${local.connections_table_arn}/index/user_id-index"] },
      { sid = "DropStaleConnections", actions = ["dynamodb:DeleteItem"], resources = [local.connections_table_arn] },
      { sid = "PushToSockets", actions = ["execute-api:ManageConnections"], resources = ["${aws_apigatewayv2_api.websocket.execution_arn}/*/POST/@connections/*"] },
      local.kms_statement,
    ]

    ws_connect = [
      { sid = "PutConnection", actions = ["dynamodb:PutItem"], resources = [local.connections_table_arn] },
      local.kms_statement,
    ]
    ws_disconnect = [
      { sid = "DeleteConnection", actions = ["dynamodb:DeleteItem"], resources = [local.connections_table_arn] },
      local.kms_statement,
    ]
    # ws_authorizer only needs its log group (the JWKS is fetched over the public internet).
  }
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.functions

  name = "permissions"
  role = aws_iam_role.lambda[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.lambda[each.key].arn}:*"]
      }],
      [for s in lookup(local.function_statements, each.key, []) : {
        Sid      = s.sid
        Effect   = "Allow"
        Action   = s.actions
        Resource = s.resources
      }],
    )
  })
}
