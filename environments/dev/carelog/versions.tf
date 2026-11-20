terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
  backend "s3" {
    key          = "dev/carelog/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.aws_account_id]
}
