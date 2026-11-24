variable "aws_region" { type = string }
variable "aws_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit DEV account ID."
  }
}
variable "name_prefix" {
  type = string
  validation {
    condition     = can(regex("(^|-)dev(-|$)", var.name_prefix))
    error_message = "name_prefix must contain a hyphen-delimited dev segment."
  }
}
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "private_subnet_ids" { type = list(string) }
variable "cluster_arn" { type = string }
variable "namespace_id" { type = string }
variable "certificate_arn" {
  type        = string
  description = "Issued ACM certificate in the ALB region."
}
variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "Approved IPv4 sources for HTTPS; restrict to the verified edge where possible."
}
variable "namespace_name" {
  type        = string
  description = "Private Cloud Map namespace name matching namespace_id."
}
variable "gateway_first_task_definition_arn" {
  type        = string
  default     = null
  description = "Optional previously registered Gateway revision; null uses the managed baseline. Releases own later revisions."
}
variable "core_first_task_definition_arn" {
  type        = string
  default     = null
  description = "Optional previously registered Core revision; null uses the managed baseline. Releases own later revisions."
}
variable "gateway_desired_count" {
  type    = number
  default = 0
  validation {
    condition     = var.gateway_desired_count >= 0 && floor(var.gateway_desired_count) == var.gateway_desired_count
    error_message = "Desired count must be a non-negative integer."
  }
}
variable "core_desired_count" {
  type    = number
  default = 0
  validation {
    condition     = var.core_desired_count >= 0 && floor(var.core_desired_count) == var.core_desired_count
    error_message = "Desired count must be a non-negative integer."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}

variable "gateway_public_alb_enabled" {
  description = "When false, the public ALB, its target group, listener and related SG rules are not created (live DEV has none)."
  type        = bool
  default     = false
}
variable "gateway_additional_containers" {
  description = "Raw ECS container definitions added beside the Gateway application container (for example cloudflared sidecars)."
  type        = any
  default     = []
}
variable "gateway_preserve" {
  description = "Preserved settings of the already-deployed Gateway service; defaults reproduce the previous behavior."
  type = object({
    assign_public_ip                      = optional(bool, false)
    execution_permissions_boundary_arn    = optional(string)
    task_permissions_boundary_arn         = optional(string)
    assume_role_source_conditions         = optional(bool, false)
    service_discovery_custom_health_check = optional(bool, false)
  })
  default = {}
}
variable "core_preserve" {
  description = "Preserved settings of the already-deployed Core service; defaults reproduce the previous behavior."
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
  default = { volume_names = [], containers = [], app_mount_points = [], app_dependencies = [] }
}

# Enrollment-capable Core image for the TLS candidate. Null keeps the live Core image (core_runtime.image).
# image: digest reference of the Core image the candidate Core task runs (pinned to the constant in core_env.tf).
# trust_init_core_base: the Core digest the trust-init image was built FROM (its label). Must equal image.
variable "enrollment_core_candidate" {
  description = "Enrollment-capable Core image for the TLS candidate; null keeps the live Core image."
  type = object({
    image                = string
    trust_init_core_base = string
  })
  default = null

  validation {
    condition     = var.enrollment_core_candidate == null || can(regex("^124495093425\\.dkr\\.ecr\\.ap-northeast-2\\.amazonaws\\.com/ranikun/platform/core@sha256:[a-f0-9]{64}$", try(var.enrollment_core_candidate.image, "")))
    error_message = "enrollment_core_candidate.image must be a digest reference to ranikun/platform/core (repo@sha256:<64 hex>)."
  }
  validation {
    condition     = var.enrollment_core_candidate == null || try(var.enrollment_core_candidate.trust_init_core_base, "") == try(var.enrollment_core_candidate.image, "-")
    error_message = "trust_init_core_base must equal enrollment_core_candidate.image (trust-init must be built FROM the candidate Core digest)."
  }
}

variable "enrollment_secret_arn" {
  description = "Existing enrollment bearer Secret ARN; null leaves enrollment disabled."
  type        = string
  default     = null
}

# Verified pushed trust-init digest for the Core candidate. Required when the candidate carries carelog-trust-init;
# the Core baseline task definition is refused at plan time unless its init image equals this reference
# (terraform_data.core_trust_init_gate in core_env.tf). Read it from the trust-init build summary, never from a tag.
variable "core_trust_init_pinned_ref" {
  description = "Pushed trust-init digest reference (core-trust-init@sha256:<64 hex>) that the Core candidate's init container must run."
  type        = string
  default     = null
  validation {
    condition     = var.core_trust_init_pinned_ref == null || can(regex("^124495093425\\.dkr\\.ecr\\.ap-northeast-2\\.amazonaws\\.com/ranikun/platform/core-trust-init@sha256:[a-f0-9]{64}$", var.core_trust_init_pinned_ref))
    error_message = "core_trust_init_pinned_ref must be a digest reference to ranikun/platform/core-trust-init in the DEV account."
  }
}

# Documentation gate for the Flyway V3 migration of the candidate Core image (NOT proof of the database state).
# The Core image 8353cec4 runs V3 at its first start (no off switch; prep-cert-secrets.md 10 and the
# evidence-flyway-v9.md section 6). Required whenever the Core image differs from the live image, with the
# enrollment flag on or off. Terraform only checks that the fields are present, that the reference is not a
# placeholder, and that the time is ISO-8601. The reference is the approved change, and v3_state_checked_at is
# when the read-only V3 status queries (carelog-tls-ecs-rollout-rollback.md section 8.1) were last run.
variable "core_v3_db_change_approval" {
  description = "Documentation gate, not proof: change reference and the time the read-only Flyway V3 status was checked. Required when the Core image differs from the live image."
  type = object({
    reference           = string
    v3_state_checked_at = string
  })
  default = null
}

variable "carelog_enrollment_host" {
  description = "Cloud Map name of the Carelog enrollment endpoint. The enrollment base URL must be exactly https://<this host>:8443."
  type        = string
  default     = "ranikun-carelog-dev-api.dev.internal"
}
