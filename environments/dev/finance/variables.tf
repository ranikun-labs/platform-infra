variable "region" { type = string }
variable "aws_account_id" {
  description = "Expected target account; provider rejects any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply a 12-digit AWS account ID."
  }
}
# Supply only the required shared/platform outputs, not their entire state.
variable "shared" {
  type = object({
    vpc_id             = string
    private_subnet_ids = list(string)
    cluster_arn        = string
    namespace_id       = string
  })
}
variable "gateway_security_group_id" { type = string }
variable "runtime" {
  type = object({
    image                     = string
    ecr_repository_arn        = string
    container_port            = number
    cpu                       = number
    memory                    = number
    initial_desired_count     = optional(number, 0)
    environment               = map(string)
    secrets                   = map(string)
    execution_secret_arns     = set(string)
    execution_kms_key_arns    = set(string)
    app_policy_json           = optional(string)
    first_task_definition_arn = optional(string)
    health_check = object({
      command      = list(string)
      interval     = number
      timeout      = number
      retries      = number
      start_period = number
    })
    log_retention_days = number
  })
}
variable "tags" {
  type    = map(string)
  default = {}
}
