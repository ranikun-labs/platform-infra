variable "gateway_cloudflared" {
  description = "Optional DEV Tunnel connector config. In Cloudflare map the API hostname to http://localhost:8080. Provide an ARN for the token."
  type = object({
    image              = string
    ecr_repository_arn = string
    token_secret_arn   = string
  })
  default = null
  validation {
    condition     = var.enable_alb || var.gateway_cloudflared != null
    error_message = "A Tunnel connector is required when ALB is disabled."
  }
}
