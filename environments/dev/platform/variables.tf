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
  default     = true
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

variable "enrollment_secret_arn" {
  description = "Existing enrollment bearer Secret ARN; null leaves enrollment disabled."
  type        = string
  default     = null
}
