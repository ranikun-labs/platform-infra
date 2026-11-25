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

  # TLS enrollment sidecar (carelog_core_auth.https_enrollment). Terminates TLS on the task IP:8443 and forwards to the
  # app on 127.0.0.1:8080. The app keeps its 8080 mapping unchanged, so Gateway and Core claims paths are not affected.
  tls_enabled = var.carelog_core_auth.enabled && var.carelog_core_auth.https_enrollment != null
  tls_volume  = "carelog-tls"
  tls_port    = 8443
  # Cloud Map name of the Carelog service (module name below). Core verifies this host against the certificate SAN.
  tls_container = local.tls_enabled ? [{
    name         = "carelog-tls-proxy"
    image        = var.carelog_core_auth.https_enrollment.proxy_image
    essential    = true
    portMappings = [{ containerPort = local.tls_port, protocol = "tcp" }]
    mountPoints  = [{ sourceVolume = local.tls_volume, containerPath = "/run/carelog-tls", readOnly = false }]
    secrets      = [{ name = "TLS_BUNDLE_JSON", valueFrom = var.carelog_core_auth.https_enrollment.server_bundle_secret_arn }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/dev-carelog"
        awslogs-region        = var.region
        awslogs-stream-prefix = "tls-proxy"
      }
    }
    # ECS ignores the image HEALTHCHECK. Proves: nginx master alive, TASK_IP:8443 listening, the served certificate equals
    # the bundle certificate file, and the app is reachable on loopback 8080.
    healthCheck = {
      command     = ["CMD-SHELL", "kill -0 $(cat /run/nginx.pid) && IP=$(grep -o 'listen [0-9.]*:8443' /etc/nginx/conf.d/default.conf | head -n 1 | cut -d' ' -f2 | cut -d: -f1) && nc -z $IP 8443 && nc -z 127.0.0.1 8080 && S=$(openssl s_client -connect $IP:8443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2) && F=$(openssl x509 -in /run/carelog-tls/server.crt -noout -fingerprint -sha256 | cut -d= -f2) && [ -n \"$S\" ] && [ \"$S\" = \"$F\" ]"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 300
    }
  }] : []
}

module "service" {
  source                         = "../../../modules/ecs-service"
  region                         = var.region
  name                           = "dev-carelog"
  cluster_arn                    = var.shared.cluster_arn
  vpc_id                         = var.shared.vpc_id
  private_subnet_ids             = var.workload_public_ip ? var.workload_public_subnet_ids : var.shared.private_subnet_ids
  assign_public_ip               = var.workload_public_ip
  namespace_id                   = var.shared.namespace_id
  image                          = var.runtime.image
  ecr_repository_arn             = var.runtime.ecr_repository_arn
  container_port                 = var.runtime.container_port
  cpu                            = var.runtime.cpu
  memory                         = var.runtime.memory
  desired_count                  = var.runtime.initial_desired_count
  environment                    = merge(var.runtime.environment, local.core_auth_environment)
  secrets                        = var.runtime.secrets
  execution_secret_arns          = local.tls_enabled ? setunion(var.runtime.execution_secret_arns, toset([var.carelog_core_auth.https_enrollment.server_bundle_secret_arn])) : var.runtime.execution_secret_arns
  execution_kms_key_arns         = local.tls_enabled ? setunion(var.runtime.execution_kms_key_arns, var.carelog_core_auth.https_enrollment.kms_key_arns) : var.runtime.execution_kms_key_arns
  app_policy_json                = var.runtime.app_policy_json
  first_task_definition_arn      = var.runtime.first_task_definition_arn
  health_check                   = var.runtime.health_check
  log_retention_days             = var.runtime.log_retention_days
  volume_names                   = setunion(var.carelog_core_auth.enabled ? toset([local.runtime_config_volume]) : toset([]), local.tls_enabled ? toset([local.tls_volume]) : toset([]))
  additional_containers          = local.tls_container
  additional_ecr_repository_arns = local.tls_enabled ? toset([var.carelog_core_auth.https_enrollment.ecr_repository_arn]) : toset([])
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

# Core reaches the TLS enrollment listener only (8443, enrollment path). Claims stay on the product port.
resource "aws_vpc_security_group_ingress_rule" "core_enrollment_tls" {
  count                        = local.tls_enabled ? 1 : 0
  security_group_id            = module.service.security_group_id
  referenced_security_group_id = var.carelog_core_auth.core_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.tls_port
  to_port                      = local.tls_port
  description                  = "Core to carelog private enrollment TLS"
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
