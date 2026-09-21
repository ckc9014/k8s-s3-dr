# Package the Python handler into a zip at plan time.
data "archive_file" "validator" {
  type        = "zip"
  source_file = "${path.module}/../lambda/handler.py"
  output_path = "${path.module}/.build/validator.zip"
}


resource "aws_iam_role" "lambda_validator" {
  name = "k8s-dr-validator-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_validator" {
  name = "k8s-dr-validator-policy"
  role = aws_iam_role.lambda_validator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadBackupBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:HeadObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*"
        ]
      },
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "ConsumeQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.backup_events.arn
      }
    ]
  })
}

resource "aws_lambda_function" "validator" {
  function_name    = "k8s-dr-backup-validator"
  role             = aws_iam_role.lambda_validator.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.validator.output_path
  source_code_hash = data.archive_file.validator.output_base64sha256

  environment {
    variables = {
      MIN_SIZE_BYTES = tostring(var.min_backup_size_bytes)
    }
  }
}

resource "aws_lambda_event_source_mapping" "validator" {
  event_source_arn = aws_sqs_queue.backup_events.arn
  function_name    = aws_lambda_function.validator.arn
  batch_size       = 10
  enabled          = true
}