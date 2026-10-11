variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "aws_profile" {
  type    = string
  default = "k8s-dr-eu"
}

variable "bucket_prefix" {
  type    = string
  default = "k8s-dr-eu-tfstate"
}