# Kasten K10 backup bucket.
resource "aws_s3_bucket" "backups" {
  bucket = "${var.bucket_prefix}-${data.aws_caller_identity.current.account_id}"
}


resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "transition-and-expire"
    status = "Enabled"

    # Empty filter = applies to all objects in the bucket.
    filter {}

    transition {
      days          = var.backup_retention_days
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.backup_expiry_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}