locals {
  # carelog-be prod profile contract for DEV, applied only with carelog_core_auth.enabled. These win over
  # runtime.environment. Sources: application-prod.yml, EnrollmentController (@ConditionalOnProperty
  # carelog.identity.enrollment.enabled), InternalIdentityClaimsController.
  core_auth_environment = var.carelog_core_auth.enabled ? {
    SPRING_PROFILES_ACTIVE                   = "prod"
    CARELOG_ENVIRONMENT                      = "dev"
    CARELOG_FLYWAY_ENABLED                   = "false"
    SPRING_FLYWAY_ENABLED                    = "false"
    VALKEY_TLS_ENABLED                       = tostring(var.carelog_core_auth.valkey_tls_enabled)
    CARELOG_IDENTITY_ENROLLMENT_ENABLED      = "true"
    CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED = "true"
  } : {}
  # /run/secrets is required by the prod configtree import (spring.config.import, non-optional).
  runtime_config_volume = "runtime-config"
}

module "service" {
  source                    = "../../../modules/ecs-service"
  region                    = var.region
  name                      = "dev-carelog"
  cluster_arn               = var.shared.cluster_arn
  vpc_id                    = var.shared.vpc_id
  private_subnet_ids        = var.workload_public_ip ? var.workload_public_subnet_ids : var.shared.private_subnet_ids
  assign_public_ip          = var.workload_public_ip
  namespace_id              = var.shared.namespace_id
  image                     = var.runtime.image
  ecr_repository_arn        = var.runtime.ecr_repository_arn
  container_port            = var.runtime.container_port
  cpu                       = var.runtime.cpu
  memory                    = var.runtime.memory
  desired_count             = var.runtime.initial_desired_count
  environment               = merge(var.runtime.environment, local.core_auth_environment)
  secrets                   = var.runtime.secrets
  execution_secret_arns     = var.runtime.execution_secret_arns
  execution_kms_key_arns    = var.runtime.execution_kms_key_arns
  app_policy_json           = var.runtime.app_policy_json
  first_task_definition_arn = var.runtime.first_task_definition_arn
  health_check              = var.runtime.health_check
  log_retention_days        = var.runtime.log_retention_days
  volume_names              = var.carelog_core_auth.enabled ? toset([local.runtime_config_volume]) : toset([])
  app_mount_points = var.carelog_core_auth.enabled ? [{
    source_volume  = local.runtime_config_volume
    container_path = "/run/secrets"
    read_only      = true
  }] : []
  tags = var.tags
}

# Gateway reaches carelog on the product port (unchanged).
resource "aws_vpc_security_group_ingress_rule" "gateway" {
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.gateway_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.runtime.container_port
  to_port                      = var.runtime.container_port
  description                  = "Gateway to carelog"
}

# Core calls carelog enrollment (PUT) and internal claims (GET) on the product port.
# Each endpoint is separately guarded by its own bearer secret in the application.
resource "aws_vpc_security_group_ingress_rule" "core" {
  count                        = var.carelog_core_auth.enabled ? 1 : 0
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.carelog_core_auth.core_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.runtime.container_port
  to_port                      = var.runtime.container_port
  description                  = "Core to carelog enrollment and claims"
}
