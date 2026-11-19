variable "region" { type = string }
variable "name" { type = string }
variable "cluster_arn" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "namespace_id" { type = string }
variable "image" {
  type = string
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "Image must be pinned to a sha256 digest."
  }
}
variable "ecr_repository_arn" { type = string }
variable "container_port" { type = number }
variable "cpu" { type = number }
variable "memory" { type = number }
variable "desired_count" { type = number }
variable "environment" { type = map(string) }
variable "secrets" { type = map(string) }
variable "execution_secret_arns" { type = set(string) }
variable "execution_kms_key_arns" { type = set(string) }
variable "app_policy_json" {
  type    = string
  default = null
}
variable "health_check" {
  type = object({
    command      = list(string)
    interval     = number
    timeout      = number
    retries      = number
    start_period = number
  })
}
variable "log_retention_days" { type = number }
variable "tags" { type = map(string) }
variable "first_task_definition_arn" {
  type    = string
  default = null
}
variable "target_group_arn" {
  type    = string
  default = null
}
variable "health_check_grace_period_seconds" {
  type    = number
  default = 60
}
