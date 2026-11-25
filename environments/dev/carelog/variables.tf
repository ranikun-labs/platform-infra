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
# namespace_name builds the TLS origin host and the proxy SAN (required when https_enrollment is set).
variable "shared" {
  type = object({
    vpc_id             = string
    private_subnet_ids = list(string)
    cluster_arn        = string
    namespace_id       = string
    namespace_name     = optional(string)
  })
}
variable "gateway_security_group_id" { type = string }

# DEV opt-in for Core-to-Carelog enrollment and internal claims. Off by default: with enabled = false every
# input below is ignored and the task definition matches the pre-change baseline. When enabled it sets the
# carelog-be prod-profile contract (main.tf), mounts /run/secrets and opens the Core ingress rule.
variable "carelog_core_auth" {
  description = "DEV-only opt-in for Core enrollment and claims. valkey_tls_enabled and core_security_group_id are required when enabled."
  type = object({
    enabled                = optional(bool, false)
    valkey_tls_enabled     = optional(bool)
    core_security_group_id = optional(string)
    # Private HTTPS enrollment listener (TLS sidecar on task IP 8443, enrollment path only). Null = no sidecar.
    # Secret values never go here: the bundle is referenced by Secrets Manager ARN only.
    https_enrollment = optional(object({
      proxy_image              = string # repo@sha256:<64 hex>, digest pinned
      ecr_repository_arn       = string
      server_bundle_secret_arn = string # secret holding certificate and key as TLS_BUNDLE_JSON, no JSON-key suffix
      kms_key_arns             = optional(set(string), [])
    }))
  })
  default = {}
  validation {
    condition = !var.carelog_core_auth.enabled || (
      var.carelog_core_auth.valkey_tls_enabled != null && var.carelog_core_auth.core_security_group_id != null
    )
    error_message = "carelog_core_auth requires valkey_tls_enabled and core_security_group_id when enabled."
  }
  validation {
    condition     = var.carelog_core_auth.core_security_group_id == null || can(regex("^sg-[0-9a-f]+$", var.carelog_core_auth.core_security_group_id))
    error_message = "core_security_group_id must be a security group ID (sg-...)."
  }
  validation {
    condition     = var.carelog_core_auth.https_enrollment == null || var.carelog_core_auth.enabled
    error_message = "carelog_core_auth.https_enrollment requires carelog_core_auth.enabled = true."
  }
  validation {
    condition     = !var.carelog_core_auth.enabled || var.carelog_core_auth.https_enrollment != null
    error_message = "carelog_core_auth.enabled requires carelog_core_auth.https_enrollment: Core reaches Carelog only through the TLS listener on 8443."
  }
  validation {
    condition     = var.carelog_core_auth.https_enrollment == null || var.shared.namespace_name != null
    error_message = "https_enrollment needs shared.namespace_name: the TLS origin host and proxy SAN are <service>.<namespace>."
  }
  validation {
    condition = var.carelog_core_auth.https_enrollment == null || (
      can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$", var.carelog_core_auth.https_enrollment.proxy_image))
    )
    error_message = "https_enrollment.proxy_image must be a private ECR image pinned by digest (repo@sha256:...)."
  }
  validation {
    condition = var.carelog_core_auth.https_enrollment == null || (
      can(regex("^arn:aws:ecr:[a-z0-9-]+:[0-9]{12}:repository/[a-z0-9._/-]+$", var.carelog_core_auth.https_enrollment.ecr_repository_arn)) &&
      can(regex("^arn:aws:secretsmanager:[^:]+:[0-9]{12}:secret:[^:]+$", var.carelog_core_auth.https_enrollment.server_bundle_secret_arn))
    )
    error_message = "https_enrollment needs an ECR repository ARN and a Secrets Manager secret ARN (no JSON-key suffix)."
  }
}

# Every check below that is new on this branch applies only when carelog_core_auth.enabled, so the default
# plan accepts exactly the inputs the baseline accepted.
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
    condition = !var.carelog_core_auth.enabled || alltrue([for k in [
      "SPRING_DATASOURCE_URL", "REDIS_HOST", "REDIS_PORT", "CARELOG_CORS_ALLOWED_ORIGINS",
      "JWT_ACCESS_TOKEN_VALIDITY", "JWT_REFRESH_TOKEN_VALIDITY",
    ] : contains(keys(var.runtime.environment), k)])
    error_message = "With carelog_core_auth enabled, runtime.environment must set SPRING_DATASOURCE_URL, REDIS_HOST, REDIS_PORT, CARELOG_CORS_ALLOWED_ORIGINS, JWT_ACCESS_TOKEN_VALIDITY and JWT_REFRESH_TOKEN_VALIDITY. Fixed DEV flags are set by main.tf."
  }
  validation {
    condition = !var.carelog_core_auth.enabled || alltrue([for k in [
      "SPRING_DATASOURCE_USERNAME", "SPRING_DATASOURCE_PASSWORD", "JWT_SECRET_KEY", "GATEWAY_INTERNAL_SECRET",
      "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET", "CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET",
    ] : contains(keys(var.runtime.secrets), k)])
    error_message = "With carelog_core_auth enabled, runtime.secrets must reference the DB credentials, JWT key, gateway secret, enrollment write secret and claims read secret."
  }
  validation {
    condition     = !var.carelog_core_auth.enabled || alltrue([for v in values(var.runtime.secrets) : can(regex("^arn:aws:(secretsmanager|ssm):", v))])
    error_message = "With carelog_core_auth enabled, every runtime.secrets value must be a Secrets Manager or SSM Parameter Store reference ARN. Never supply secret values."
  }
  validation {
    condition     = !var.carelog_core_auth.enabled || alltrue([for v in values(var.runtime.secrets) : anytrue([for a in var.runtime.execution_secret_arns : startswith(v, a)])])
    error_message = "With carelog_core_auth enabled, each secret reference must be covered by execution_secret_arns (exact underlying ARN, without JSON-key suffix)."
  }
  validation {
    # Compare underlying secret ARNs: strip any ECS JSON-key suffix (secretsmanager ARNs have 7 colon-separated parts).
    condition = !var.carelog_core_auth.enabled || length(distinct([for k in [
      "GATEWAY_INTERNAL_SECRET", "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET", "CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET",
      ] : join(":", slice(split(":", lookup(var.runtime.secrets, k, "")), 0, min(7, length(split(":", lookup(var.runtime.secrets, k, ""))))))
    ])) == 3
    error_message = "With carelog_core_auth enabled, the gateway, enrollment and claims secret ARNs must be pairwise distinct."
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

# Preserved settings of the DEV service that already runs (live facts, not opt-ins). Every default equals the module's
# previous behavior, so an unset input plans the same as before. The live values go into dev-live-preserve.auto.tfvars.
variable "preserve" {
  description = "Live-service preservation inputs. Defaults reproduce the previous behavior; ARNs are placeholders in the examples."
  type = object({
    assign_public_ip                      = optional(bool, false)
    execution_permissions_boundary_arn    = optional(string)
    task_permissions_boundary_arn         = optional(string)
    assume_role_source_conditions         = optional(bool, false)
    service_discovery_custom_health_check = optional(bool, true)
    config_volume_name                    = optional(string)
    core_claims_security_group_id         = optional(string)
  })
  default = {}
  validation {
    condition = alltrue([for a in [
      var.preserve.execution_permissions_boundary_arn, var.preserve.task_permissions_boundary_arn,
    ] : a == null || can(regex("^arn:aws:iam::[0-9]{12}:policy/.+$", a))])
    error_message = "Permissions boundaries must be IAM policy ARNs."
  }
  validation {
    condition     = var.preserve.core_claims_security_group_id == null || can(regex("^sg-[0-9a-f]+$", var.preserve.core_claims_security_group_id))
    error_message = "preserve.core_claims_security_group_id must be a security group ID (sg-...)."
  }
}

# Keep null. Overrides the Cloud Map and ECS service name (default dev-carelog). A different value renames live
# resources, so the naming and state decision is pending.
variable "service_name_override" {
  type    = string
  default = null
  validation {
    condition     = var.service_name_override == null || can(regex("^[a-z][a-z0-9-]{0,62}$", var.service_name_override))
    error_message = "service_name_override must be a lowercase DNS label."
  }
}
