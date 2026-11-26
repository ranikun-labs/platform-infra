variable "aws_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply the 12-digit DEV account ID."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "This DEV root is pinned to ap-northeast-2."
  }
}
variable "github_oidc_provider_arn" {
  type        = string
  description = "ARN of the existing account-wide GitHub OIDC provider; managed by its separate owner."
  validation {
    condition     = var.github_oidc_provider_arn == "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
    error_message = "Use the existing GitHub provider in the DEV account."
  }
}
variable "state_bucket_name" {
  type        = string
  description = "Existing DEV Terraform state bucket (created and authorized separately). Must match the bucket passed at init."
  validation {
    condition     = var.state_bucket_name == "ranikun-dev-tfstate-${var.aws_account_id}"
    error_message = "Use the DEV state bucket for this account."
  }
}
variable "state_kms_key_arn" {
  type        = string
  default     = null
  description = "Set only if the state bucket default encryption is SSE-KMS with a customer key. Null means no KMS statement."
  validation {
    condition     = var.state_kms_key_arn == null || can(regex("^arn:aws:kms:ap-northeast-2:${var.aws_account_id}:key/", var.state_kms_key_arn))
    error_message = "The state KMS key must be a key in this account and region."
  }
}
variable "cluster_name" {
  type        = string
  default     = "dev-shared"
  description = "DEV ECS cluster that hosts the carelog and platform services (read-only refresh)."
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]*dev[A-Za-z0-9_-]*$", var.cluster_name))
    error_message = "Cluster name must contain dev and use ECS name characters."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}
