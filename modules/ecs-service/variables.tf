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

variable "cloudflared" {
  description = "Optional DEV Cloudflare Tunnel connector sharing the gateway Task network. Use a mirrored image and a dedicated Secrets Manager token."
  type = object({
    image              = string
    ecr_repository_arn = string
    token_secret_arn   = string
  })
  default = null
  validation {
    condition = var.cloudflared == null ? true : (
      can(regex("@sha256:[0-9a-f]{64}$", var.cloudflared.image)) &&
      can(regex("^arn:aws:ecr:[^:]+:[0-9]{12}:repository/.+$", var.cloudflared.ecr_repository_arn)) &&
      can(regex("^arn:aws:secretsmanager:[^:]+:[0-9]{12}:secret:.+$", var.cloudflared.token_secret_arn))
    )
    error_message = "The Tunnel connector requires a digest-pinned image, ECR repository ARN and Secrets Manager token ARN."
  }
}

variable "assign_public_ip" {
  type    = bool
  default = false
}

variable "volume_names" {
  description = "Ephemeral task-level volumes. Empty keeps the task definition unchanged."
  type        = set(string)
  default     = []
}

variable "app_mount_points" {
  description = "Mount points for the application container; each source_volume must be in volume_names. Empty keeps the container definition unchanged."
  type = list(object({
    source_volume  = string
    container_path = string
    read_only      = optional(bool, true)
  }))
  default = []
  validation {
    condition     = alltrue([for m in var.app_mount_points : contains(var.volume_names, m.source_volume)])
    error_message = "Every app mount point must reference a volume declared in volume_names."
  }
  validation {
    condition     = alltrue([for m in var.app_mount_points : startswith(m.container_path, "/")])
    error_message = "Mount container_path must be absolute."
  }
}
