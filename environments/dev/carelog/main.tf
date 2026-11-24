# Values handed to the module, exposed through outputs so tests can assert them
# (test assertions cannot address resources inside module.service).
locals {
  app_environment = merge(var.runtime.environment, var.enrollment_tls_candidate.environment)
  # Explicit [] removes the app's 8080 mapping. null (the variable default) makes the module emit
  # containerPort 8080 for the app container, which would collide with the proxy on the task IP.
  app_port_mappings = var.enrollment_tls_candidate.app_port_mappings
}

module "service" {
  source                                = "../../../modules/ecs-service"
  assign_public_ip                      = var.preserve.assign_public_ip
  execution_permissions_boundary_arn    = var.preserve.execution_permissions_boundary_arn
  task_permissions_boundary_arn         = var.preserve.task_permissions_boundary_arn
  assume_role_source_conditions         = var.preserve.assume_role_source_conditions
  service_discovery_custom_health_check = var.preserve.service_discovery_custom_health_check
  region                                = var.region
  name                                  = "ranikun-carelog-dev-api"
  cluster_arn                           = var.shared.cluster_arn
  vpc_id                                = var.shared.vpc_id
  private_subnet_ids                    = var.shared.private_subnet_ids
  namespace_id                          = var.shared.namespace_id
  image                                 = var.runtime.image
  ecr_repository_arn                    = var.runtime.ecr_repository_arn
  container_port                        = var.runtime.container_port
  cpu                                   = var.runtime.cpu
  memory                                = var.runtime.memory
  desired_count                         = var.runtime.initial_desired_count
  environment                           = local.app_environment
  secrets                               = merge(var.runtime.secrets, var.enrollment_secret_arn == null ? {} : { CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET = var.enrollment_secret_arn })
  execution_secret_arns                 = setunion(var.runtime.execution_secret_arns, var.enrollment_tls_candidate.secret_arns, var.enrollment_secret_arn == null ? toset([]) : toset([var.enrollment_secret_arn]))
  execution_kms_key_arns                = setunion(var.runtime.execution_kms_key_arns, var.enrollment_tls_candidate.kms_key_arns)
  additional_ecr_repository_arns        = var.enrollment_tls_candidate.ecr_repository_arns
  additional_volume_names               = setunion(var.runtime.additional_volume_names, var.enrollment_tls_candidate.volume_names)
  app_mount_points                      = concat(var.runtime.app_mount_points, var.enrollment_tls_candidate.app_mount_points)
  app_port_mappings                     = local.app_port_mappings
  app_container_dependencies            = var.enrollment_tls_candidate.app_dependencies
  additional_containers                 = var.enrollment_tls_candidate.containers
  app_policy_json                       = var.runtime.app_policy_json
  first_task_definition_arn             = var.runtime.first_task_definition_arn
  health_check                          = var.runtime.health_check
  log_retention_days                    = var.runtime.log_retention_days
  tags                                  = var.tags
}
resource "aws_vpc_security_group_ingress_rule" "gateway" {
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.gateway_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.runtime.container_port
  to_port                      = var.runtime.container_port
  description                  = "Gateway to carelog"
}

resource "aws_vpc_security_group_ingress_rule" "core_enrollment_tls" {
  count                        = var.enrollment_core_security_group_id == null ? 0 : 1
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.enrollment_core_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  description                  = "Core to Carelog private enrollment TLS"
}

# Rule that already exists in the DEV state; declared so a plan does not delete it.
resource "aws_vpc_security_group_ingress_rule" "core_claims" {
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.core_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.runtime.container_port
  to_port                      = var.runtime.container_port
  description                  = "Core to Carelog identity claims"
}
