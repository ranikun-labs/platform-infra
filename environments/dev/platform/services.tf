variable "gateway_runtime" {
  description = "Baseline task settings. Override revisions must use the correct roles, service container name and ports."
  type = object({
    image                  = string
    ecr_repository_arn     = string
    cpu                    = number
    memory                 = number
    environment            = map(string)
    secrets                = map(string)
    execution_secret_arns  = set(string)
    execution_kms_key_arns = set(string)
    health_check           = object({ command = list(string), interval = number, timeout = number, retries = number, start_period = number })
    log_retention_days     = number
  })
  # Checked only with dev_dual_auth.enabled. Canonical PLATFORM_GATEWAY_* names only (names, never values).
  validation {
    condition = !var.dev_dual_auth.enabled || alltrue([for k in [
      "PLATFORM_GATEWAY_CARELOG_RAG_URI", "PLATFORM_GATEWAY_CARELOG_BE_URI",
      "PLATFORM_GATEWAY_REDIS_HOST", "PLATFORM_GATEWAY_REDIS_PORT", "PLATFORM_GATEWAY_REDIS_KEY_PREFIX",
    ] : contains(keys(var.gateway_runtime.environment), k)])
    error_message = "With dev_dual_auth enabled, gateway_runtime.environment must set PLATFORM_GATEWAY_CARELOG_RAG_URI, PLATFORM_GATEWAY_CARELOG_BE_URI, PLATFORM_GATEWAY_REDIS_HOST, PLATFORM_GATEWAY_REDIS_PORT and PLATFORM_GATEWAY_REDIS_KEY_PREFIX."
  }
  validation {
    condition = !var.dev_dual_auth.enabled || alltrue([for k in [
      "PLATFORM_GATEWAY_INTERNAL_SECRET", "PLATFORM_GATEWAY_JWT_VERIFICATION_SECRET",
    ] : contains(keys(var.gateway_runtime.secrets), k)])
    error_message = "With dev_dual_auth enabled, gateway_runtime.secrets must reference PLATFORM_GATEWAY_INTERNAL_SECRET and PLATFORM_GATEWAY_JWT_VERIFICATION_SECRET."
  }
}
variable "core_runtime" {
  description = "Baseline task settings; override revisions must use the correct roles and service container name."
  type = object({
    image                  = string
    ecr_repository_arn     = string
    cpu                    = number
    memory                 = number
    environment            = map(string)
    secrets                = map(string)
    execution_secret_arns  = set(string)
    execution_kms_key_arns = set(string)
    health_check           = object({ command = list(string), interval = number, timeout = number, retries = number, start_period = number })
    log_retention_days     = number
  })
  # Checked only with dev_dual_auth.enabled. Names only; a key may come from environment or secrets.
  validation {
    condition = !var.dev_dual_auth.enabled || alltrue([for k in [
      "PLATFORM_IDENTITY_REDIS_HOST", "PLATFORM_IDENTITY_REDIS_PORT",
      "PLATFORM_IDENTITY_DATASOURCE_URL", "PLATFORM_IDENTITY_DATASOURCE_USERNAME", "PLATFORM_IDENTITY_DATASOURCE_PASSWORD",
      "PLATFORM_IDENTITY_JWT_SECRET_KEY",
    ] : contains(concat(keys(var.core_runtime.environment), keys(var.core_runtime.secrets)), k)])
    error_message = "With dev_dual_auth enabled, core_runtime must provide PLATFORM_IDENTITY_REDIS_HOST, PLATFORM_IDENTITY_REDIS_PORT, PLATFORM_IDENTITY_DATASOURCE_URL, PLATFORM_IDENTITY_DATASOURCE_USERNAME, PLATFORM_IDENTITY_DATASOURCE_PASSWORD and PLATFORM_IDENTITY_JWT_SECRET_KEY (environment or secrets)."
  }
  validation {
    condition     = !var.dev_dual_auth.enabled || var.core_truststore == null || !contains(concat(keys(var.core_runtime.environment), keys(var.core_runtime.secrets)), "JAVA_TOOL_OPTIONS")
    error_message = "core_runtime must not set JAVA_TOOL_OPTIONS when core_truststore is set; the truststore setting owns it."
  }
}

# Composed container inputs. The dual-auth maps override runtime values on the keys they name; dev_dual_auth
# SPRING_PROFILES_ACTIVE therefore replaces any runtime profile when enabled.
locals {
  gateway_container_environment = merge(var.gateway_runtime.environment, local.gateway_dual_env, {
    PLATFORM_GATEWAY_PORT            = "8080"
    PLATFORM_GATEWAY_MANAGEMENT_PORT = "9091"
    PLATFORM_GATEWAY_AUTH_URI        = "http://${var.name_prefix}-core.${var.namespace_name}:8081"
  })
  gateway_container_secrets   = merge(var.gateway_runtime.secrets, local.gateway_dual_secrets)
  gateway_container_execution = setunion(var.gateway_runtime.execution_secret_arns, toset(values(local.gateway_dual_secrets)))
  core_container_environment  = merge(var.core_runtime.environment, local.core_dual_env, local.core_truststore_env, { PLATFORM_CORE_PORT = "8081" })
  core_container_secrets      = merge(var.core_runtime.secrets, local.core_dual_secrets)
  core_container_execution    = setunion(var.core_runtime.execution_secret_arns, toset(values(local.core_dual_secrets)))

  # Core truststore (dev_dual_auth + core_truststore). The init container writes /run/carelog-trust/cacerts; the app
  # reads it read-only. Empty when off, so the default task definition is unchanged.
  core_truststore_on     = var.dev_dual_auth.enabled && var.core_truststore != null
  core_truststore_volume = "core-truststore"
  core_trust_init_name   = "core-trust-init"
  core_truststore_env    = local.core_truststore_on ? { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" } : {}
  core_trust_init_containers = local.core_truststore_on ? [{
    name        = local.core_trust_init_name
    image       = var.core_truststore.trust_init_image
    essential   = false
    mountPoints = [{ sourceVolume = local.core_truststore_volume, containerPath = "/run/carelog-trust", readOnly = false }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/${var.name_prefix}-core"
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "trust-init"
      }
    }
  }] : []
}
module "gateway" {
  source                                = "../../../modules/ecs-service"
  region                                = var.aws_region
  name                                  = "${var.name_prefix}-gateway"
  cluster_arn                           = var.cluster_arn
  vpc_id                                = var.vpc_id
  private_subnet_ids                    = var.workload_public_ip ? var.public_subnet_ids : var.private_subnet_ids
  assign_public_ip                      = var.workload_public_ip || var.gateway_preserve.assign_public_ip
  namespace_id                          = var.namespace_id
  image                                 = var.gateway_runtime.image
  ecr_repository_arn                    = var.gateway_runtime.ecr_repository_arn
  container_port                        = 8080
  cpu                                   = var.gateway_runtime.cpu
  memory                                = var.gateway_runtime.memory
  desired_count                         = var.gateway_desired_count
  first_task_definition_arn             = var.gateway_first_task_definition_arn
  target_group_arn                      = var.enable_alb ? aws_lb_target_group.gateway[0].arn : null
  environment                           = local.gateway_container_environment
  secrets                               = local.gateway_container_secrets
  execution_secret_arns                 = local.gateway_container_execution
  execution_kms_key_arns                = var.gateway_runtime.execution_kms_key_arns
  health_check                          = var.gateway_runtime.health_check
  log_retention_days                    = var.gateway_runtime.log_retention_days
  tags                                  = var.tags
  cloudflared                           = var.gateway_cloudflared
  depends_on                            = [aws_lb_listener.https]
  execution_permissions_boundary_arn    = var.gateway_preserve.execution_permissions_boundary_arn
  task_permissions_boundary_arn         = var.gateway_preserve.task_permissions_boundary_arn
  assume_role_source_conditions         = var.gateway_preserve.assume_role_source_conditions
  service_discovery_custom_health_check = var.gateway_preserve.service_discovery_custom_health_check
}
module "core" {
  source                                = "../../../modules/ecs-service"
  region                                = var.aws_region
  name                                  = "${var.name_prefix}-core"
  cluster_arn                           = var.cluster_arn
  vpc_id                                = var.vpc_id
  private_subnet_ids                    = var.workload_public_ip ? var.public_subnet_ids : var.private_subnet_ids
  assign_public_ip                      = var.workload_public_ip || var.core_preserve.assign_public_ip
  namespace_id                          = var.namespace_id
  image                                 = var.core_runtime.image
  ecr_repository_arn                    = var.core_runtime.ecr_repository_arn
  container_port                        = 8081
  cpu                                   = var.core_runtime.cpu
  memory                                = var.core_runtime.memory
  desired_count                         = var.core_desired_count
  first_task_definition_arn             = var.core_first_task_definition_arn
  environment                           = local.core_container_environment
  secrets                               = local.core_container_secrets
  execution_secret_arns                 = local.core_container_execution
  execution_kms_key_arns                = var.core_runtime.execution_kms_key_arns
  health_check                          = var.core_runtime.health_check
  log_retention_days                    = var.core_runtime.log_retention_days
  volume_names                          = local.core_truststore_on ? toset([local.core_truststore_volume]) : toset([])
  app_mount_points                      = local.core_truststore_on ? [{ source_volume = local.core_truststore_volume, container_path = "/run/carelog-trust", read_only = true }] : []
  additional_containers                 = local.core_trust_init_containers
  additional_ecr_repository_arns        = local.core_truststore_on ? toset([var.core_truststore.ecr_repository_arn]) : toset([])
  app_depends_on                        = local.core_truststore_on ? [{ container_name = local.core_trust_init_name, condition = "SUCCESS" }] : []
  tags                                  = var.tags
  execution_permissions_boundary_arn    = var.core_preserve.execution_permissions_boundary_arn
  task_permissions_boundary_arn         = var.core_preserve.task_permissions_boundary_arn
  assume_role_source_conditions         = var.core_preserve.assume_role_source_conditions
  service_discovery_custom_health_check = var.core_preserve.service_discovery_custom_health_check
}
resource "aws_vpc_security_group_egress_rule" "alb_gateway" {
  for_each                     = var.enable_alb ? toset(["8080", "9091"]) : toset([])
  security_group_id            = aws_security_group.alb[0].id
  referenced_security_group_id = module.gateway.security_group_id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "gateway_alb" {
  for_each                     = var.enable_alb ? toset(["8080", "9091"]) : toset([])
  security_group_id            = module.gateway.security_group_id
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "core_gateway" {
  security_group_id            = module.core.security_group_id
  referenced_security_group_id = module.gateway.security_group_id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
}
output "gateway_security_group_id" { value = module.gateway.security_group_id }
output "core_security_group_id" { value = module.core.security_group_id }
# Composed container inputs, exposed for the contract test (module internals are not addressable from a test).
output "gateway_container_environment" { value = local.gateway_container_environment }
output "gateway_container_secrets" { value = local.gateway_container_secrets }
output "core_container_environment" { value = local.core_container_environment }
output "core_container_secrets" { value = local.core_container_secrets }
output "gateway_service_name" { value = module.gateway.service_name }
output "core_service_name" { value = module.core.service_name }
output "alb_dns_name" { value = var.enable_alb ? aws_lb.gateway[0].dns_name : null }
output "alb_zone_id" { value = var.enable_alb ? aws_lb.gateway[0].zone_id : null }
output "gateway_baseline_task_definition_arn" { value = module.gateway.baseline_task_definition_arn }
output "core_baseline_task_definition_arn" { value = module.core.baseline_task_definition_arn }
