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
}

run "dev_trusted_context_requires_secret_arn" {
  command = plan
  variables {
    dev_trusted_context = { enabled = true }
  }
  expect_failures = [var.dev_trusted_context]
}

run "flyway_at_startup_is_rejected" {
  command = plan
  variables {
    runtime = {
      container_port         = 8080
      image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/finance@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/finance"
      cpu                    = 256
      memory                 = 512
      environment            = { SPRING_FLYWAY_ENABLED = "true" }
      secrets                = {}
      execution_secret_arns  = []
      execution_kms_key_arns = []
      health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
      log_retention_days     = 7
    }
  }
  expect_failures = [var.runtime]
}
