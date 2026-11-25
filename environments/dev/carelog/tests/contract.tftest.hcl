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
    container_port     = 8080
    image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog"
    cpu                = 256
    memory             = 512
    environment = {
      SPRING_DATASOURCE_URL        = "jdbc:postgresql://carelog-db.example.internal:5432/carelog"
      REDIS_HOST                   = "carelog-valkey.example.internal"
      REDIS_PORT                   = "6379"
      CARELOG_CORS_ALLOWED_ORIGINS = "https://dev-carelog.example.internal"
      JWT_ACCESS_TOKEN_VALIDITY    = "900000"
      JWT_REFRESH_TOKEN_VALIDITY   = "1209600000"
    }
    secrets = {
      SPRING_DATASOURCE_USERNAME                      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/db-user"
      SPRING_DATASOURCE_PASSWORD                      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/db-password"
      JWT_SECRET_KEY                                  = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/jwt"
      GATEWAY_INTERNAL_SECRET                         = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/gateway"
      CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/enrollment"
      CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/claims"
    }
    execution_secret_arns = [
      "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/db-user",
      "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/db-password",
      "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/jwt",
      "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/gateway",
      "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/enrollment",
      "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/claims",
    ]
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

run "core_ingress_is_opt_in" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.core) == 0
    error_message = "Core ingress must be absent until its security group is supplied."
  }
}

run "core_ingress_and_runtime_config_mount" {
  command = plan

  variables {
    core_security_group_id = "sg-0123456789abcdef1"
    runtime_config_mount   = true
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.core) == 1 && aws_vpc_security_group_ingress_rule.core[0].referenced_security_group_id == "sg-0123456789abcdef1" && aws_vpc_security_group_ingress_rule.core[0].from_port == 8080
    error_message = "Only the supplied Core security group may reach the product port through the Core rule."
  }
}

run "rejects_plaintext_secret_values" {
  command = plan

  variables {
    runtime = merge(var.runtime, {
      secrets = merge(var.runtime.secrets, { JWT_SECRET_KEY = "not-an-arn-plaintext-value" })
    })
  }

  expect_failures = [var.runtime]
}
