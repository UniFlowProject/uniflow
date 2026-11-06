# Messaging: SNS topic, SQS queues + DLQs, EventBridge Scheduler role/group and optional SES identity.

locals {
  queues = toset(["expirations", "in-app-notifications", "email-notifications"])
  # Queues fed by the SNS topic.
  sns_queues = toset(["in-app-notifications", "email-notifications"])
}

resource "aws_sns_topic" "notifications" {
  name              = "${var.project-tag}-notifications"
  kms_master_key_id = aws_kms_key.shared.arn

  tags = {
    Name = "${var.project-tag}-notifications"
  }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = "${var.project-tag}-${each.key}-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.shared.arn

  tags = {
    Name = "${var.project-tag}-${each.key}-dlq"
  }
}

resource "aws_sqs_queue" "this" {
  for_each = local.queues

  name                       = "${var.project-tag}-${each.key}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
  kms_master_key_id          = aws_kms_key.shared.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.sqs_max_receive_count
  })

  tags = {
    Name = "${var.project-tag}-${each.key}"
  }
}

data "aws_iam_policy_document" "queue" {
  for_each = local.queues

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.this[each.key].arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  dynamic "statement" {
    for_each = contains(local.sns_queues, each.key) ? [1] : []

    content {
      sid       = "AllowSnsTopic"
      actions   = ["sqs:SendMessage"]
      resources = [aws_sqs_queue.this[each.key].arn]

      principals {
        type        = "Service"
        identifiers = ["sns.amazonaws.com"]
      }

      condition {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [aws_sns_topic.notifications.arn]
      }
    }
  }

  dynamic "statement" {
    for_each = each.key == "expirations" ? [1] : []

    content {
      sid       = "AllowSchedulerRole"
      actions   = ["sqs:SendMessage"]
      resources = [aws_sqs_queue.this[each.key].arn]

      principals {
        type        = "AWS"
        identifiers = [aws_iam_role.scheduler.arn]
      }
    }
  }
}

resource "aws_sqs_queue_policy" "this" {
  for_each = local.queues

  queue_url = aws_sqs_queue.this[each.key].url
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

resource "aws_sns_topic_subscription" "queues" {
  for_each = local.sns_queues

  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.this[each.key].arn
}

# --- EventBridge Scheduler -> expirations queue ---

resource "aws_scheduler_schedule_group" "this" {
  name = var.project-tag

}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "scheduler_send" {
  statement {
    sid       = "SendToExpirations"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.this["expirations"].arn]
  }

  statement {
    sid       = "UseQueueKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.shared.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.project-tag}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json

}

resource "aws_iam_role_policy" "scheduler_send" {
  name   = "send-to-expirations"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_send.json
}

# --- SES ---

resource "aws_sesv2_email_identity" "sender" {
  count          = var.ses_sender_email != null ? 1 : 0
  email_identity = var.ses_sender_email

}
