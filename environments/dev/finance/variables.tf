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

# DEV-only trusted-context receiver (dev profile) for the Gateway-routed Finance task. Off by default.
# The secret must be the same secret as platform's dev_dual_auth.finance_trusted_context_secret_arn.
variable "dev_trusted_context" {
  type = object({
    enabled    = bool
    secret_arn = optional(string)
  })
  default     = { enabled = false }
  description = "Enables the trusted-context receiver under the dev profile. Never combine with a prod profile or marker."
  validation {
    condition = !var.dev_trusted_context.enabled || (
      var.dev_trusted_context.secret_arn != null &&
      can(regex("^arn:aws:secretsmanager:[^:]+:[0-9]{12}:secret:[^:]+$", var.dev_trusted_context.secret_arn))
    )
    error_message = "dev_trusted_context requires a Secrets Manager secret ARN (without a JSON-key suffix) when enabled."
  }
}

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

variable "workload_public_ip" {
  type    = bool
  default = false
}
variable "workload_public_subnet_ids" {
  type    = list(string)
  default = []
  validation {
    condition     = !var.workload_public_ip || length(var.workload_public_subnet_ids) > 0
    error_message = "Public IP tasks require explicit public subnets."
  }
}
