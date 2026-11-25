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
  default     = null
  validation {
    condition     = !var.enable_alb || (var.certificate_arn == null ? false : can(regex("^arn:aws:acm:", var.certificate_arn)))
    error_message = "An ACM certificate ARN is required when ALB is enabled."
  }
}
variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "Approved IPv4 sources for HTTPS; restrict to the verified edge where possible."
  default     = []
  validation {
    condition     = !var.enable_alb || length(var.alb_ingress_cidrs) > 0
    error_message = "ALB requires at least one approved ingress CIDR."
  }
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

variable "enable_alb" {
  type    = bool
  default = true
}
variable "workload_public_ip" {
  type    = bool
  default = false
}

# DEV-only dual-auth opt-in: one Core serving Carelog auth and Finance reference auth together. Off by default, so the
# baseline Core/Gateway environment is unchanged. Values are secret ARNs or origins only; never secret values.
variable "carelog_enrollment_origin" {
  type        = string
  default     = null
  description = "Private origin of DEV Carelog for Core enrollment and product claims: scheme, host and port only, no path. Core appends /api/v1/... itself. Required when dev_dual_auth.enabled."
  validation {
    condition     = var.carelog_enrollment_origin == null || can(regex("^https?://[^/?#@ ]+$", var.carelog_enrollment_origin))
    error_message = "carelog_enrollment_origin must be an http or https origin without a path, query, fragment or userinfo."
  }
  validation {
    condition     = !var.dev_dual_auth.enabled || var.carelog_enrollment_origin != null
    error_message = "carelog_enrollment_origin is required when dev_dual_auth.enabled is true."
  }
}

variable "dev_dual_auth" {
  type = object({
    enabled = bool
    # Same secret for Core's signing key and Gateway's verification key.
    jwt_signing_key_secret_arn = optional(string)
    # Gateway caller secret. The Finance receiver must reference this same secret (finance root dev_trusted_context).
    finance_trusted_context_secret_arn = optional(string)
    # Must equal Carelog's enrollment credential (Carelog side: CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET).
    carelog_enrollment_secret_arn = optional(string)
    # Must equal Carelog's internal identity claims secret (Carelog side: CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET).
    product_claims_secret_arn = optional(string)
    finance_service_name      = optional(string, "dev-finance")
    finance_container_port    = optional(number, 8080)
    # Required when enabled (no default). Must match the Valkey endpoint actually in use; true only once managed Valkey TLS is verified end to end (see README).
    redis_tls_enabled = optional(bool)
  })
  default     = { enabled = false }
  description = "DEV-only dual-auth opt-in (Core Carelog + Finance reference, Gateway Finance route). Guards in platform-services reject prod markers."
  validation {
    condition = !var.dev_dual_auth.enabled || alltrue([
      for arn in [
        var.dev_dual_auth.jwt_signing_key_secret_arn,
        var.dev_dual_auth.finance_trusted_context_secret_arn,
        var.dev_dual_auth.carelog_enrollment_secret_arn,
        var.dev_dual_auth.product_claims_secret_arn,
      ] : arn != null && can(regex("^arn:aws:secretsmanager:[^:]+:[0-9]{12}:secret:[^:]+$", arn))
    ])
    error_message = "dev_dual_auth requires Secrets Manager secret ARNs (without JSON-key suffixes) for all four secret fields."
  }
  validation {
    condition     = !var.dev_dual_auth.enabled || var.dev_dual_auth.redis_tls_enabled != null
    error_message = "dev_dual_auth.redis_tls_enabled is required when dev_dual_auth.enabled is true; set it to match the Valkey endpoint in use."
  }
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.dev_dual_auth.finance_service_name)) && var.dev_dual_auth.finance_container_port > 0 && var.dev_dual_auth.finance_container_port < 65536
    error_message = "finance_service_name must be a Cloud Map DNS label and finance_container_port a valid TCP port."
  }
}
