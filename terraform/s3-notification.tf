
resource "aws_s3_bucket_notification" "backups" {
  bucket = aws_s3_bucket.backups.id

  queue {
    queue_arn     = aws_sqs_queue.backup_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "k10/"
  }

  depends_on = [aws_sqs_queue_policy.backup_events]
}