# Queue that receives S3 ObjectCreated events for backup validation.
resource "aws_sqs_queue" "backup_events" {
  name                       = "k8s-dr-kasten10-backup-events"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 10

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.backup_events_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "backup_events_dlq" {
  name                      = "k8s-dr-kasten10-backup-events-dlq"
  message_retention_seconds = 1209600  # 14 days
}

resource "aws_sqs_queue_redrive_allow_policy" "backup_events_dlq" {
  queue_url = aws_sqs_queue.backup_events_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.backup_events.arn]
  })
}

data "aws_iam_policy_document" "sqs_s3_send" {
  statement {
    sid     = "AllowS3ToSendMessages"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sqs_queue.backup_events.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.backups.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "backup_events" {
  queue_url = aws_sqs_queue.backup_events.id
  policy    = data.aws_iam_policy_document.sqs_s3_send.json
}