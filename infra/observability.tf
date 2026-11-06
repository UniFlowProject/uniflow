# Observability: API access log group, alarm SNS topic and DLQ depth alarms.

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.project-tag}-access"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.shared.arn

  tags = {
    projects = var.project-tag
  }
}

resource "aws_sns_topic" "alarms" {
  name              = "${var.project-tag}-alarms"
  kms_master_key_id = aws_kms_key.shared.arn

  tags = {
    projects = var.project-tag
  }
}

resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email != null ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  for_each = local.queues

  alarm_name          = "${var.project-tag}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages are sitting in the ${each.key} DLQ"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]

  tags = {
    projects = var.project-tag
  }
}
