module "service" {
  source                    = "../../../modules/ecs-service"
  region                    = var.region
  name                      = "dev-carelog"
  cluster_arn               = var.shared.cluster_arn
  vpc_id                    = var.shared.vpc_id
  private_subnet_ids        = var.shared.private_subnet_ids
  namespace_id              = var.shared.namespace_id
  image                     = var.runtime.image
  ecr_repository_arn        = var.runtime.ecr_repository_arn
  container_port            = var.runtime.container_port
  cpu                       = var.runtime.cpu
  memory                    = var.runtime.memory
  desired_count             = var.runtime.initial_desired_count
  environment               = var.runtime.environment
  secrets                   = var.runtime.secrets
  execution_secret_arns     = var.runtime.execution_secret_arns
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
  description                  = "Gateway to carelog"
}
