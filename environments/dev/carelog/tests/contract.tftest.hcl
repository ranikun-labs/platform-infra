mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  region         = "ap-northeast-2"
  aws_account_id = "111122223333"
  shared = {
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_arn        = "arn:aws:ecs:ap-northeast-2:111122223333:cluster/test-dev"
    namespace_id       = "ns-0123456789abcdef0"
  }
  gateway_security_group_id = "sg-0123456789abcdef0"
  core_security_group_id    = "sg-0123456789abcdef1"
  runtime = {
    container_port         = 8080
    image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog"
    cpu                    = 256
    memory                 = 512
    environment            = {}
    secrets                = {}
    execution_secret_arns  = []
    execution_kms_key_arns = []
    health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
    log_retention_days     = 7
  }
}

run "gateway_only_service_ingress" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.gateway.referenced_security_group_id == var.gateway_security_group_id && aws_vpc_security_group_ingress_rule.gateway.from_port == var.runtime.container_port && var.runtime.initial_desired_count == 0
    error_message = "Only SCG should be able to reach the private product port, with a zero-task bootstrap."
  }
}

run "preserves_existing_core_claims_rule_and_defaults" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.core_claims.referenced_security_group_id == var.core_security_group_id && aws_vpc_security_group_ingress_rule.core_claims.from_port == var.runtime.container_port
    error_message = "The existing Core-to-Carelog claims rule must stay declared so a plan does not delete it."
  }

  assert {
    condition     = var.preserve.assign_public_ip == false && var.preserve.service_discovery_custom_health_check == false
    error_message = "Preservation inputs must default to the previous module behavior."
  }
}

# Mirrors carelog.tfvars.example (enrollment_tls_candidate). Placeholders are syntactically valid, not real ARNs.
run "enrollment_candidate_app_env_and_port_mappings" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = { SERVER_ADDRESS = "127.0.0.1", CARELOG_IDENTITY_ENROLLMENT_ENABLED = "true", SPRING_FLYWAY_ENABLED = "false" }
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"]
      secret_arns         = []
      kms_key_arns        = []
      containers = [{
        name             = "carelog-tls-proxy"
        image            = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential        = true
        portMappings     = [{ containerPort = 8080, protocol = "tcp" }, { containerPort = 8443, protocol = "tcp" }]
        mountPoints      = [{ sourceVolume = "carelog-tls", containerPath = "/run/carelog-tls", readOnly = false }]
        secrets          = []
        logConfiguration = { logDriver = "awslogs", options = { awslogs-group = "/ecs/ranikun-carelog-dev-api", awslogs-region = "ap-northeast-2", awslogs-stream-prefix = "tls-proxy" } }
        healthCheck      = { command = ["CMD-SHELL", "kill -0 $(cat /run/nginx.pid) || exit 1"], interval = 30, timeout = 3, retries = 3, startPeriod = 10 }
      }]
    }
  }

  # Explicit empty list: the app container gets no portMappings, so 8080 belongs only to the proxy.
  assert {
    condition     = length(output.app_port_mappings) == 0 && output.app_port_mappings != null
    error_message = "App port mappings must be an explicit empty list so the app does not claim 8080 on the task IP."
  }

  assert {
    condition     = output.app_environment["CARELOG_IDENTITY_ENROLLMENT_ENABLED"] == "true" && output.app_environment["SPRING_FLYWAY_ENABLED"] == "false" && output.app_environment["SERVER_ADDRESS"] == "127.0.0.1"
    error_message = "Candidate app env must enable enrollment, disable Flyway through the variable the release guard reads, and bind Spring to 127.0.0.1."
  }

  assert {
    condition     = output.app_environment["CARELOG_IDENTITY_ENROLLMENT_ENABLED"] == "true" && alltrue([for k in keys(output.app_environment) : !endswith(k, "SECRET") && !endswith(k, "PASSWORD")])
    error_message = "Plain app environment must not carry secret-named keys."
  }
}

# Documents the trap: when the candidate omits app_port_mappings the module emits containerPort 8080 for the app.
run "unset_app_port_mappings_is_null_module_default" {
  command = plan

  assert {
    condition     = output.app_port_mappings == null
    error_message = "Default enrollment_tls_candidate must leave app_port_mappings null (module default 8080). Candidate inputs must set []."
  }
}
