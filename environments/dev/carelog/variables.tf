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
  validation {
    condition = alltrue([for k in [
      "SPRING_DATASOURCE_URL", "REDIS_HOST", "REDIS_PORT", "CARELOG_CORS_ALLOWED_ORIGINS",
      "JWT_ACCESS_TOKEN_VALIDITY", "JWT_REFRESH_TOKEN_VALIDITY",
    ] : contains(keys(var.runtime.environment), k)])
    error_message = "runtime.environment must set SPRING_DATASOURCE_URL, REDIS_HOST, REDIS_PORT, CARELOG_CORS_ALLOWED_ORIGINS, JWT_ACCESS_TOKEN_VALIDITY and JWT_REFRESH_TOKEN_VALIDITY. Fixed DEV flags are set by main.tf."
  }
  validation {
    condition = alltrue([for k in [
      "SPRING_DATASOURCE_USERNAME", "SPRING_DATASOURCE_PASSWORD", "JWT_SECRET_KEY", "GATEWAY_INTERNAL_SECRET",
      "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET", "CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET",
    ] : contains(keys(var.runtime.secrets), k)])
    error_message = "runtime.secrets must reference the DB credentials, JWT key, gateway secret, enrollment write secret and claims read secret."
  }
  validation {
    condition     = alltrue([for v in values(var.runtime.secrets) : can(regex("^arn:aws:(secretsmanager|ssm):", v))])
    error_message = "Every runtime.secrets value must be a Secrets Manager or SSM Parameter Store reference ARN. Never supply secret values."
  }
  validation {
    condition     = alltrue([for v in values(var.runtime.secrets) : anytrue([for a in var.runtime.execution_secret_arns : startswith(v, a)])])
    error_message = "Each secret reference must be covered by execution_secret_arns (exact underlying ARN, without JSON-key suffix)."
  }
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

variable "runtime_config_mount" {
  description = "Mount an empty ephemeral volume at /run/secrets so the prod configtree import resolves. Required for DEV boot with the current application-prod.yml; secrets still come from env references."
  type        = bool
  default     = false
}

variable "core_security_group_id" {
  description = "Core service security group that may call carelog on the product port (enrollment and claims). Null adds no rule."
  type        = string
  default     = null
  validation {
    condition     = var.core_security_group_id == null ? true : can(regex("^sg-[0-9a-f]+$", var.core_security_group_id))
    error_message = "Supply a security group ID (sg-...) or null."
  }
}
