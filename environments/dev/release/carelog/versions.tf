terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.24.0"
    }
  }
  backend "s3" {
    key          = "dev/release/carelog/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
}
