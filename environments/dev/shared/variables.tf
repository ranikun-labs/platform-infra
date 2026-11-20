variable "aws_region" {
  description = "Target AWS region, independently supplied for the backend during init."
  type        = string
  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "A target region is required."
  }
}
variable "aws_account_id" {
  description = "Expected target account; provider rejects any other account."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply a 12-digit AWS account ID."
  }
}
variable "vpc_cidr" {
  type = string
  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Supply an IPv4 VPC CIDR."
  }
}
variable "availability_zones" {
  description = "Two distinct AZ names in the selected region."
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "Supply exactly two distinct availability zones."
  }
}
variable "public_subnet_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) == 2 && alltrue([for cidr in var.public_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "Supply two IPv4 public subnet CIDRs."
  }
}
variable "private_subnet_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) == 2 && alltrue([for cidr in var.private_subnet_cidrs : can(cidrnetmask(cidr))])
    error_message = "Supply two IPv4 private subnet CIDRs."
  }
}
variable "enable_nat_gateway" {
  description = "One shared DEV NAT provides outbound access, including external OAuth. Disable only when private workloads have another egress path."
  type        = bool
  default     = true
}
variable "database_engine_version" {
  description = "Explicit Aurora PostgreSQL version supported by Serverless v2 in the selected region."
  type        = string
}
variable "database_name" {
  type    = string
  default = "app"
}
variable "database_master_username" {
  type    = string
  default = "dbadmin"
}
variable "database_min_capacity" {
  description = "Serverless v2 minimum ACUs. Set to 0 only with a compatible Aurora version and auto-pause support."
  type        = number
  default     = 0.5
  validation {
    condition     = contains([0, 0.5, 1, 1.5, 2], var.database_min_capacity)
    error_message = "DEV minimum must be 0, 0.5, 1, 1.5, or 2 ACUs."
  }
}
variable "database_auto_pause_seconds" {
  description = "Idle interval for min 0; ignored otherwise."
  type        = number
  default     = 900
  validation {
    condition     = var.database_auto_pause_seconds >= 300 && var.database_auto_pause_seconds <= 86400
    error_message = "Auto-pause must be between 300 and 86400 seconds."
  }
}
variable "enable_valkey" {
  description = "Provision a private, single-node DEV Valkey cache."
  type        = bool
  default     = false
}
variable "valkey_engine_version" {
  type    = string
  default = "7.2"
}
variable "valkey_node_type" {
  type    = string
  default = "cache.t4g.micro"
}
variable "namespace_name" {
  description = "Private Cloud Map DNS namespace."
  type        = string
  default     = "dev.internal"
}

variable "database_ingress_security_group_ids" {
  description = "Named workload security group IDs approved for PostgreSQL access. Supply after service roots create their groups."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for id in values(var.database_ingress_security_group_ids) : can(regex("^sg-[0-9a-f]{8}([0-9a-f]{9})?$", id))])
    error_message = "Database ingress sources must be security group IDs."
  }
}
variable "valkey_ingress_security_group_ids" {
  description = "Named workload security group IDs approved for Valkey access. Supply after service roots create their groups."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for id in values(var.valkey_ingress_security_group_ids) : can(regex("^sg-[0-9a-f]{8}([0-9a-f]{9})?$", id))])
    error_message = "Valkey ingress sources must be security group IDs."
  }
}
