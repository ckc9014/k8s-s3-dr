variable "aws_region" {
  description = "AWS region for lab resources."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile name (SSO)."
  type        = string
  default     = "k8s-dr-eu"
}

variable "bucket_prefix" {
  description = "Prefix for the S3 backup bucket."
  type        = string
  default     = "k8s-dr-eu-backups"
}

variable "backup_retention_days" {
  description = "Days before transitioning backups to STANDARD_IA."
  type        = number
  default     = 30
}

variable "backup_expiry_days" {
  description = "Days before expiring backups entirely."
  type        = number
  default     = 365
}

variable "min_backup_size_bytes" {
  description = "Minimum size (bytes) a backup object must have to pass validation."
  type        = number
  default     = 1024
}