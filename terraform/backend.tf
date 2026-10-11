terraform {
  backend "s3" {
    key     = "k8s-s3-dr/terraform.tfstate"
    encrypt = true
  }
}