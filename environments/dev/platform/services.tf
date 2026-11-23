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
}
module "gateway" {
  source                    = "../../../modules/ecs-service"
  region                    = var.aws_region
  name                      = "${var.name_prefix}-gateway"
  cluster_arn               = var.cluster_arn
  vpc_id                    = var.vpc_id
  private_subnet_ids        = var.private_subnet_ids
  namespace_id              = var.namespace_id
  image                     = var.gateway_runtime.image
  ecr_repository_arn        = var.gateway_runtime.ecr_repository_arn
  container_port            = 8080
  cpu                       = var.gateway_runtime.cpu
  memory                    = var.gateway_runtime.memory
  desired_count             = var.gateway_desired_count
  first_task_definition_arn = var.gateway_first_task_definition_arn
  target_group_arn          = aws_lb_target_group.gateway.arn
  environment = merge(var.gateway_runtime.environment, {
    PLATFORM_GATEWAY_PORT            = "8080"
    PLATFORM_GATEWAY_MANAGEMENT_PORT = "9091"
    PLATFORM_GATEWAY_AUTH_URI        = "http://${var.name_prefix}-core.${var.namespace_name}:8081"
  })
  secrets                = var.gateway_runtime.secrets
  execution_secret_arns  = var.gateway_runtime.execution_secret_arns
  execution_kms_key_arns = var.gateway_runtime.execution_kms_key_arns
  health_check           = var.gateway_runtime.health_check
  log_retention_days     = var.gateway_runtime.log_retention_days
  tags                   = var.tags
  depends_on             = [aws_lb_listener.https]
}
module "core" {
  additional_volume_names    = var.enrollment_tls_candidate.volume_names
  additional_containers      = var.enrollment_tls_candidate.containers
  app_mount_points           = var.enrollment_tls_candidate.app_mount_points
  app_container_dependencies = var.enrollment_tls_candidate.app_dependencies
  source                     = "../../../modules/ecs-service"
  region                     = var.aws_region
  name                       = "${var.name_prefix}-core"
  cluster_arn                = var.cluster_arn
  vpc_id                     = var.vpc_id
  private_subnet_ids         = var.private_subnet_ids
  namespace_id               = var.namespace_id
  image                      = var.core_runtime.image
  ecr_repository_arn         = var.core_runtime.ecr_repository_arn
  container_port             = 8081
  cpu                        = var.core_runtime.cpu
  memory                     = var.core_runtime.memory
  desired_count              = var.core_desired_count
  first_task_definition_arn  = var.core_first_task_definition_arn
  environment                = merge(var.core_runtime.environment, { PLATFORM_CORE_PORT = "8081" })
  secrets                    = merge(var.core_runtime.secrets, var.enrollment_secret_arn == null ? {} : { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL = var.enrollment_secret_arn })
  execution_secret_arns      = setunion(var.core_runtime.execution_secret_arns, var.enrollment_secret_arn == null ? toset([]) : toset([var.enrollment_secret_arn]))
  execution_kms_key_arns     = var.core_runtime.execution_kms_key_arns
  health_check               = var.core_runtime.health_check
  log_retention_days         = var.core_runtime.log_retention_days
  tags                       = var.tags
}
resource "aws_vpc_security_group_egress_rule" "alb_gateway" {
  for_each                     = toset(["8080", "9091"])
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = module.gateway.security_group_id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "gateway_alb" {
  for_each                     = toset(["8080", "9091"])
  security_group_id            = module.gateway.security_group_id
  referenced_security_group_id = aws_security_group.alb.id
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
output "gateway_service_name" { value = module.gateway.service_name }
output "core_service_name" { value = module.core.service_name }
output "alb_dns_name" { value = aws_lb.gateway.dns_name }
output "alb_zone_id" { value = aws_lb.gateway.zone_id }
output "gateway_baseline_task_definition_arn" { value = module.gateway.baseline_task_definition_arn }
output "core_baseline_task_definition_arn" { value = module.core.baseline_task_definition_arn }
