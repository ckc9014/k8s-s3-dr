output "bucket_name" {
  description = "S3 bucket holding Kasten backups."
  value       = aws_s3_bucket.backups.id
}

output "bucket_arn" {
  description = "ARN of the backup bucket."
  value       = aws_s3_bucket.backups.arn
}

output "bucket_region" {
  description = "Region of the backup bucket."
  value       = aws_s3_bucket.backups.region
}

output "sqs_queue_url" {
  description = "SQS queue receiving S3 ObjectCreated events."
  value       = aws_sqs_queue.backup_events.url
}

output "sqs_queue_arn" {
  description = "ARN of the SQS queue."
  value       = aws_sqs_queue.backup_events.arn
}

output "lambda_function_arn" {
  description = "ARN of the validation Lambda."
  value       = aws_lambda_function.validator.arn
}

output "lambda_function_name" {
  description = "Name of the validation Lambda."
  value       = aws_lambda_function.validator.function_name
}

output "sqs_dlq_url" {
  value = aws_sqs_queue.backup_events_dlq.url
}

output "sqs_dlq_arn" {
  value = aws_sqs_queue.backup_events_dlq.arn
}