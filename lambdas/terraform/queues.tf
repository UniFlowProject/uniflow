# SQS -> Lambda event source mappings. ReportBatchItemFailures lets each handler return
# only the failed messageIds; those go back to the queue and, after the root stack's
# maxReceiveCount, to the DLQ.

locals {
  queue_consumers = {
    process_expiration  = local.platform.expirations_queue_arn
    send_email          = local.platform.email_queue_arn
    in_app_notification = local.platform.in_app_queue_arn
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  for_each = local.queue_consumers

  event_source_arn        = each.value
  function_name           = aws_lambda_function.this[each.key].arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = var.sqs_max_concurrency
  }
}
