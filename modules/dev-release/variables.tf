variable "aws_account_id" { type = string }
variable "aws_region" { type = string }
variable "github_repository" { type = string }
variable "github_oidc_provider_arn" { type = string }
variable "cluster_name" { type = string }
variable "service_name" { type = string }
variable "tags" { type = map(string) }
variable "workload" { type = string }
variable "ecr_repository_name" { type = string }


variable "github_repository_owner_id" {
  type        = string
  description = "Observed immutable GitHub owner ID; not an account name or a minted-token claim assertion."
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "Supply the observed numeric GitHub repository owner ID."
  }
}
variable "github_repository_id" {
  type        = string
  description = "Observed immutable GitHub repository ID."
  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "Supply the observed numeric GitHub repository ID."
  }
}
variable "github_oidc_subjects" {
  type        = object({ publish = string, deploy = string })
  description = "Exact per-environment sub values, confirmed by a filtered diagnostic in this caller repository/environment. No defaults or wildcard trust."
  validation {
    condition = alltrue([
      for operation, subject in var.github_oidc_subjects : try(subject == format(
        "repo:%s@%s/%s@%s:environment:dev-%s-%s",
        split("/", var.github_repository)[0], var.github_repository_owner_id,
        split("/", var.github_repository)[1], var.github_repository_id,
        var.workload, operation
      ), false)
    ])
    error_message = "Each exact subject must bind this repository name, immutable owner/repository IDs, workload and its publish/deploy environment; empty, legacy, wildcard or cross-target values are rejected."
  }
}
