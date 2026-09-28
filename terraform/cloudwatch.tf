# --- Alarm 1: Lambda is erroring ------------------------------------------
# Fires as soon as the validator starts failing. Early warning.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "k8s-dr-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "Kasten validator Lambda is erroring repeatedly."

  dimensions = {
    FunctionName = aws_lambda_function.validator.function_name
  }
}

# --- Alarm 2: DLQ is not empty --------------------------------------------
# Fires ~90s later, after SQS exhausts its 3 retries. Late confirmation.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "k8s-dr-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Messages are landing in the Kasten validator DLQ."

  dimensions = {
    QueueName = aws_sqs_queue.backup_events_dlq.name
  }
}