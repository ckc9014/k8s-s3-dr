terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = "k8s-dr"
      Environment = "lab"
      ManagedBy   = "terraform"
    }
  }
}

# Used to build a globally-unique S3 bucket name (account ID suffix).
data "aws_caller_identity" "current" {}