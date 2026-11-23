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

# Preservation options. Defaults reproduce the previous module behavior.
variable "assign_public_ip" {
  description = "Fargate public IP for tasks; required when the subnets have no NAT or VPC endpoints for image pulls."
  type        = bool
  default     = false
}
variable "execution_permissions_boundary_arn" {
  type    = string
  default = null
}
variable "task_permissions_boundary_arn" {
  type    = string
  default = null
}
variable "assume_role_source_conditions" {
  description = "Add aws:SourceAccount and aws:SourceArn (ECS) conditions to the task role trust policies."
  type        = bool
  default     = false
}
variable "service_discovery_custom_health_check" {
  description = "Declare health_check_custom_config on the Cloud Map service. Changing it replaces the service."
  type        = bool
  default     = false
}
variable "additional_volume_names" {
  type    = set(string)
  default = []
}
variable "additional_containers" {
  description = "Raw ECS container definitions added beside the application container (for example sidecars)."
  type        = any
  default     = []
}
variable "app_mount_points" {
  type    = list(object({ sourceVolume = string, containerPath = string, readOnly = bool }))
  default = []
}
variable "app_container_dependencies" {
  type    = list(object({ containerName = string, condition = string }))
  default = []
}
variable "additional_ecr_repository_arns" {
  type    = set(string)
  default = []
}
variable "app_port_mappings" {
  type    = list(object({ containerPort = number, protocol = string }))
  default = null
}
