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
