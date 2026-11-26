variable "gateway_cloudflared" {
  description = "Optional DEV Tunnel connector config. In Cloudflare map the API hostname to http://localhost:8080. Provide an ARN for the token."
  type = object({
    image              = string
    ecr_repository_arn = string
    token_secret_arn   = string
  })
  default = null
  validation {
    condition     = var.enable_alb || var.gateway_cloudflared != null || length(var.gateway_additional_containers) > 0
    error_message = "A Tunnel connector is required when ALB is disabled: gateway_cloudflared or gateway_additional_containers."
  }
  validation {
    condition     = length(var.gateway_additional_containers) == 0 || var.gateway_cloudflared == null
    error_message = "Use gateway_additional_containers or gateway_cloudflared for the Tunnel sidecar, not both."
  }
}

# Alternative Tunnel path that keeps a live 2-container Gateway shape (app + cloudflared) when the sidecar is not the
# module's cloudflared input. Raw ECS container definitions, appended after the app. Empty keeps the default.
variable "gateway_additional_containers" {
  description = "Raw ECS container definitions beside the Gateway app (for example a cloudflared sidecar copied from the live task). Use instead of gateway_cloudflared, not with it."
  type        = list(any)
  default     = []
  validation {
    condition     = alltrue([for c in var.gateway_additional_containers : can(regex("@sha256:[0-9a-f]{64}$", try(c.image, "")))])
    error_message = "Every gateway_additional_containers image must be digest pinned (repo@sha256:<64 hex>)."
  }
}

variable "gateway_additional_ecr_repository_arns" {
  description = "ECR repositories the Gateway execution role may pull for gateway_additional_containers images."
  type        = set(string)
  default     = []
}
