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
    additional_volume_names   = optional(set(string), [])
    app_mount_points          = optional(list(object({ sourceVolume = string, containerPath = string, readOnly = bool })), [])
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

# Preserve settings of the already-deployed service. Defaults reproduce the module's previous behavior.
variable "preserve" {
  type = object({
    assign_public_ip                      = optional(bool, false)
    execution_permissions_boundary_arn    = optional(string)
    task_permissions_boundary_arn         = optional(string)
    assume_role_source_conditions         = optional(bool, false)
    service_discovery_custom_health_check = optional(bool, false)
  })
  default = {}
}

variable "enrollment_tls_candidate" {
  description = "Disabled by default; supply only after TLS and route allowlist verification."
  type = object({
    volume_names        = set(string)
    containers          = any
    app_mount_points    = list(object({ sourceVolume = string, containerPath = string, readOnly = bool }))
    app_dependencies    = list(object({ containerName = string, condition = string }))
    ecr_repository_arns = optional(set(string), [])
    secret_arns         = optional(set(string), [])
    kms_key_arns        = optional(set(string), [])
    environment         = optional(map(string), {})
    app_port_mappings   = optional(list(object({ containerPort = number, protocol = string })))
  })

  # Single-bundle design: the proxy reads exactly one secret, TLS_BUNDLE_JSON, as a bare ARN (no json-key or
  # version suffix), and nothing else from the TLS path. The server certificate and key never come from separate
  # secrets. The proxy must carry an ECS healthCheck with a startPeriod that covers the app start (161-179 s observed).
  validation {
    condition = alltrue([for c in var.enrollment_tls_candidate.containers :
      try(c.name, "") != "carelog-tls-proxy" || try([for s in c.secrets : s.name] == ["TLS_BUNDLE_JSON"], false)
    ])
    error_message = "The carelog-tls-proxy container must read exactly one secret named TLS_BUNDLE_JSON (no TLS_CERT_PEM, TLS_KEY_PEM or CA secret)."
  }
  validation {
    condition = alltrue([for c in var.enrollment_tls_candidate.containers :
      alltrue([for s in try(c.secrets, []) :
        s.name != "TLS_BUNDLE_JSON" || (!strcontains(s.valueFrom, "::") && (!startswith(s.valueFrom, "arn:") || length(split(":", s.valueFrom)) == 7))
      ])
    ])
    error_message = "TLS_BUNDLE_JSON must reference the bare secret ARN: no json-key (:key::) and no version suffix."
  }
  validation {
    condition     = length(var.enrollment_tls_candidate.secret_arns) <= 1
    error_message = "secret_arns for the TLS candidate holds only the single bundle secret ARN."
  }
  validation {
    condition = alltrue([for c in var.enrollment_tls_candidate.containers :
      try(c.name, "") != "carelog-tls-proxy" || try(c.healthCheck.command[0] == "CMD-SHELL" && c.healthCheck.startPeriod >= 180 && c.healthCheck.retries >= 1, false)
    ])
    error_message = "The carelog-tls-proxy container needs a CMD-SHELL healthCheck with startPeriod >= 180 seconds."
  }

  default = { volume_names = [], containers = [], app_mount_points = [], app_dependencies = [] }
}

variable "enrollment_secret_arn" {
  description = "Existing enrollment bearer Secret ARN; null leaves enrollment disabled."
  type        = string
  default     = null
}

variable "enrollment_core_security_group_id" {
  description = "Core security group allowed to the enrollment TLS port; null disables rule."
  type        = string
  default     = null
}

variable "core_security_group_id" {
  description = "Platform Core security group allowed to the Carelog app port (identity claims rule that already exists in DEV)."
  type        = string
}
