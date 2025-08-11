terraform {
  backend "s3" {
    bucket  = "poc-tfstate-bucket-0123456"
    key     = "Envs/Dev/terraform.tfstate"
    region  = "us-east-2"
    encrypt = true
  }
}