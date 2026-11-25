locals {
  # Trusted-context receiver: only under DEV. FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET is the placeholder read by
  # application-dev.yml (finance.auth.trusted-context.service-secret); the Gateway injects the matching caller value.
  # SPRING_FLYWAY_ENABLED=false is forced only on this DEV path. Default plans pass runtime.environment through
  # unchanged, so the release gate's explicit-false requirement must be met by runtime.environment itself.
  dev_trusted_context_env = var.dev_trusted_context.enabled ? {
    SPRING_PROFILES_ACTIVE      = "dev"
    FINANCE_AUTH_MODE           = "trusted-context"
    FINANCE_METRICS_ENVIRONMENT = "dev"
    SPRING_FLYWAY_ENABLED       = "false"
  } : {}
  dev_trusted_context_secrets = var.dev_trusted_context.enabled ? {
    FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET = var.dev_trusted_context.secret_arn
  } : {}

  container_environment    = merge(var.runtime.environment, local.dev_trusted_context_env)
  container_secrets        = merge(var.runtime.secrets, local.dev_trusted_context_secrets)
  container_execution_arns = setunion(var.runtime.execution_secret_arns, toset(values(local.dev_trusted_context_secrets)))
}

module "service" {
  source                    = "../../../modules/ecs-service"
  region                    = var.region
  name                      = "dev-finance"
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
  environment               = local.container_environment
  secrets                   = local.container_secrets
  execution_secret_arns     = local.container_execution_arns
  execution_kms_key_arns    = var.runtime.execution_kms_key_arns
  app_policy_json           = var.runtime.app_policy_json
  first_task_definition_arn = var.runtime.first_task_definition_arn
  health_check              = var.runtime.health_check
  log_retention_days        = var.runtime.log_retention_days
  tags                      = var.tags
}
resource "aws_vpc_security_group_ingress_rule" "gateway" {
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.gateway_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.runtime.container_port
  to_port                      = var.runtime.container_port
  description                  = "Gateway to finance"
}
