# terraform {
#   backend "s3" {
#     bucket         = "my-tf-state-bucket"
#     key            = "my-dr-project/terraform.tfstate"
#     region         = "eu-west-1"
#     dynamodb_table = "my-tf-locks"
#     encrypt        = true
#     profile        = "dr-lab-eu"
#   }
# }