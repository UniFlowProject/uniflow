# Lambda functions. Code is staged by ../lambdas/build.sh into ../lambdas/.build/<dir> and zipped here.

locals {
  build_dir = "${path.module}/../lambdas/.build"

  email_env = merge(
    { USER_POOL_ID = aws_cognito_user_pool.this.id, TIMEZONE = var.email_timezone },
    var.ses_sender_email != null ? { FROM_EMAIL = var.ses_sender_email } : {},
    var.default_to_email != null ? { DEFAULT_TO_EMAIL = var.default_to_email } : {},
  )

  api_env = tomap({ NOTIFICATIONS_TABLE = aws_dynamodb_table.notifications.name })

  functions = {
    # --- REST (HTTP API) ---
    api_create = {
      dir = "notifications_api", handler = "create.handler", timeout = 10, memory = 256
      env = tomap(local.api_env)
    }
    api_list = {
      dir = "notifications_api", handler = "list.handler", timeout = 10, memory = 256
      env = tomap(local.api_env)
    }
    api_unread_count = {
      dir = "notifications_api", handler = "unread-count.handler", timeout = 10, memory = 256
      env = tomap(local.api_env)
    }
    api_mark_read = {
      dir = "notifications_api", handler = "mark-read.handler", timeout = 10, memory = 256
      env = tomap(local.api_env)
    }
    api_delete = {
      dir = "notifications_api", handler = "delete.handler", timeout = 10, memory = 256
      env = tomap(local.api_env)
    }

    # --- SQS consumers. Timeouts stay at 10s: the queues' visibility timeout is 60s (6x, per AWS guidance). ---
    process_expiration = {
      dir = "process_expiration", handler = "index.handler", timeout = 10, memory = 128
      env = tomap({ NOTIFICATIONS_TOPIC_ARN = aws_sns_topic.notifications.arn })
    }
    send_email = {
      dir = "sendEmail", handler = "index.handler", timeout = 10, memory = 256
      env = tomap(local.email_env)
    }
    in_app_notification = {
      dir = "sendExpirationReminderInAppNotification", handler = "index.handler", timeout = 10, memory = 256
      env = tomap({
        CONNECTIONS_TABLE             = aws_dynamodb_table.connections.name
        NOTIFICATIONS_TABLE           = aws_dynamodb_table.notifications.name
        CONNECTIONS_USER_INDEX        = "user_id-index"
        WEBSOCKET_MANAGEMENT_ENDPOINT = local.websocket_management_endpoint
      })
    }

    # --- WebSocket ---
    ws_authorizer = {
      dir = "lambda_authorizer", handler = "index.handler", timeout = 5, memory = 256
      env = tomap({
        USER_POOL_ID        = aws_cognito_user_pool.this.id
        USER_POOL_CLIENT_ID = aws_cognito_user_pool_client.spa.id
      })
    }
    ws_connect = {
      dir = "handle_notifications_ws_connection", handler = "index.handler", timeout = 5, memory = 128
      env = tomap({ CONNECTIONS_TABLE = aws_dynamodb_table.connections.name })
    }
    ws_disconnect = {
      dir = "handle_notifications_ws_disconnection", handler = "index.handler", timeout = 5, memory = 128
      env = tomap({ CONNECTIONS_TABLE = aws_dynamodb_table.connections.name })
    }
  }
}

data "archive_file" "lambda" {
  for_each = toset([for f in local.functions : f.dir])

  type        = "zip"
  source_dir  = "${local.build_dir}/${each.key}"
  output_path = "${path.module}/.dist/${each.key}.zip"

  lifecycle {
    precondition {
      condition     = length(fileset("${local.build_dir}/${each.key}", "*")) > 0
      error_message = "${local.build_dir}/${each.key} is missing or empty: run lambdas/build.sh before terraform plan/apply."
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.functions

  name              = "/aws/lambda/${var.project-tag}-${replace(each.key, "_", "-")}"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_lambda_function" "this" {
  for_each = local.functions

  function_name    = "${var.project-tag}-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = var.lambda_runtime
  architectures    = ["arm64"]
  handler          = each.value.handler
  timeout          = each.value.timeout
  memory_size      = each.value.memory
  filename         = data.archive_file.lambda[each.value.dir].output_path
  source_code_hash = data.archive_file.lambda[each.value.dir].output_base64sha256

  environment {
    variables = each.value.env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda[each.key].name
  }

  # CI deploys the code; Terraform only owns the configuration. The archive
  # still seeds the first create.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_iam_role_policy.lambda]
}
