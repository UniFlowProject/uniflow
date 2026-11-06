# SQS -> Lambda event source mappings. ReportBatchItemFailures lets each handler return
# only the failed messageIds; those go back to the queue and, after the
# maxReceiveCount, to the DLQ.

locals {
  queue_consumers = {
    process_expiration  = aws_sqs_queue.this["expirations"].arn
    send_email          = aws_sqs_queue.this["email-notifications"].arn
    in_app_notification = aws_sqs_queue.this["in-app-notifications"].arn
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
