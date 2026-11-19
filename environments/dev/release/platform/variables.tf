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
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.aws_region)) && !startswith(var.aws_region, "us-gov-")
    error_message = "Supply a commercial AWS region."
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
variable "cluster_name" {
  type        = string
  description = "Existing DEV ECS cluster name."
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]*dev[A-Za-z0-9_-]*$", var.cluster_name))
    error_message = "Cluster name must contain dev and use ECS name characters."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "name_prefix" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.name_prefix)) && can(regex("(^|-)dev(-|$)", var.name_prefix))
    error_message = "Use the existing platform prefix with a hyphen-delimited dev segment."
  }
}
