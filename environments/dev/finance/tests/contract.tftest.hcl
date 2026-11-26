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
  runtime = {
    container_port         = 8080
    image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/finance@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/finance"
    cpu                    = 256
    memory                 = 512
    environment            = { REDIS_HOST = "finance-valkey.example.internal" }
    secrets                = { SPRING_DATASOURCE_PASSWORD = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance/db" }
    execution_secret_arns  = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance/db"]
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

# Opt-in off: the container inputs must equal the origin/main pass-through (runtime.environment and runtime.secrets only).
run "default_container_matches_origin" {
  command = plan

  assert {
    condition     = output.container_environment == var.runtime.environment
    error_message = "With dev_trusted_context disabled the container environment must equal runtime.environment (no forced Flyway flag)."
  }
  assert {
    condition     = output.container_secrets == var.runtime.secrets
    error_message = "With dev_trusted_context disabled the container secrets must equal runtime.secrets."
  }
}

run "dev_trusted_context_plans_with_secret_arn" {
  command = plan
  variables {
    dev_trusted_context = {
      enabled    = true
      secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-trusted-context-AbCdEf"
    }
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.gateway.from_port == 8080 && var.runtime.initial_desired_count == 0
    error_message = "DEV trusted context must keep the gateway-only port and zero-task bootstrap."
  }
  assert {
    condition     = output.container_environment["SPRING_FLYWAY_ENABLED"] == "false" && output.container_environment["SPRING_PROFILES_ACTIVE"] == "dev"
    error_message = "DEV trusted context must force SPRING_FLYWAY_ENABLED=false alongside the dev profile."
  }
}

run "dev_trusted_context_requires_secret_arn" {
  command = plan
  variables {
    dev_trusted_context = { enabled = true }
  }
  expect_failures = [var.dev_trusted_context]
}

# Live preservation for the Finance service. Unset inputs keep the previous shape; set inputs reach the plan.
run "preserve_defaults_match_previous_behavior" {
  command = plan

  assert {
    condition     = var.preserve.assign_public_ip == false && var.preserve.service_discovery_custom_health_check == true && var.preserve.assume_role_source_conditions == false
    error_message = "Unset preservation inputs must keep main's behavior."
  }
}

run "live_preserve_inputs_plan" {
  command = plan

  variables {
    preserve = {
      assign_public_ip                      = true
      execution_permissions_boundary_arn    = "arn:aws:iam::111122223333:policy/dev-boundary-execution"
      task_permissions_boundary_arn         = "arn:aws:iam::111122223333:policy/dev-boundary-task"
      assume_role_source_conditions         = true
      service_discovery_custom_health_check = true
    }
  }

  assert {
    condition     = module.service.service_name != null && var.preserve.task_permissions_boundary_arn != null
    error_message = "The Finance service must plan with the live preserve inputs."
  }
}

run "preserve_rejects_non_policy_boundary" {
  command = plan

  variables {
    preserve = { execution_permissions_boundary_arn = "dev-boundary-execution" }
  }
  expect_failures = [var.preserve]
}
