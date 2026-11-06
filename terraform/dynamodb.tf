# DynamoDB tables: notifications and websocket connections.

# --- DynamoDB ---

resource "aws_dynamodb_table" "notifications" {
  name         = "${var.project-tag}-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "user_id"
  range_key    = "notification_id"

  attribute {
    name = "user_id"
    type = "S"
  }

  attribute {
    name = "notification_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.shared.arn
  }

  tags = {
    Name     = "${var.project-tag}-notifications"
    projects = var.project-tag
  }
}

resource "aws_dynamodb_table" "connections" {
  name         = "${var.project-tag}-connections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "connection_id"

  attribute {
    name = "connection_id"
    type = "S"
  }

  attribute {
    name = "user_id"
    type = "S"
  }

  global_secondary_index {
    name            = "user_id-index"
    projection_type = "ALL"

    key_schema {
      attribute_name = "user_id"
      key_type       = "HASH"
    }
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.shared.arn
  }

  tags = {
    Name     = "${var.project-tag}-connections"
    projects = var.project-tag
  }
}
