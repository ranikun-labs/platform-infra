mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  aws_region             = "ap-northeast-2"
  aws_account_id         = "111122223333"
  name_prefix            = "test-dev"
  vpc_id                 = "vpc-0123456789abcdef0"
  private_subnet_ids     = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  public_subnet_ids      = ["subnet-0123456789abcdef2", "subnet-0123456789abcdef3"]
  cluster_arn            = "arn:aws:ecs:ap-northeast-2:111122223333:cluster/test-dev"
  namespace_id           = "ns-0123456789abcdef0"
  namespace_name         = "dev.internal"
  certificate_arn        = "arn:aws:acm:ap-northeast-2:111122223333:certificate/11111111-1111-1111-1111-111111111111"
  alb_ingress_cidrs      = ["192.0.2.0/24"]
  gateway_readiness_path = "/actuator/health/readiness"
  gateway_runtime = {
    image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/gateway@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/gateway"
    cpu                    = 256
    memory                 = 512
    environment            = {}
    secrets                = {}
    execution_secret_arns  = []
    execution_kms_key_arns = []
    health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
    log_retention_days     = 7
  }
  core_runtime = {
    image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/core"
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

run "https_ingress_and_audit_disabled" {
  command = plan

  assert {
    condition     = aws_lb_listener.https[0].protocol == "HTTPS" && aws_lb_target_group.gateway[0].target_type == "ip" && aws_lb_target_group.gateway[0].health_check[0].port == "9091"
    error_message = "HTTPS must target SCG through its IP target group and separate readiness port."
  }
  assert {
    condition     = length(aws_sqs_queue.audit) == 0 && length(aws_sqs_queue.audit_dlq) == 0
    error_message = "Audit messaging must be opt-in."
  }
}

run "audit_enabled_with_explicit_contract" {
  command = plan

  variables {
    audit_contract = {
      reference           = "test-only-fixture"
      producer_role_names = ["test-dev-core-task"]
      consumer_role_name  = "test-dev-audit-task"
      visibility_timeout  = 60
      max_receive_count   = 5
      alarm_actions       = ["arn:aws:sns:ap-northeast-2:111122223333:test-dev-alarms"]
    }
  }

  assert {
    condition     = length(aws_sqs_queue.audit_dlq) == 1 && aws_sqs_queue.audit[0].sqs_managed_sse_enabled && aws_sqs_queue.audit_dlq[0].sqs_managed_sse_enabled
    error_message = "Audit delivery must use encryption and a dedicated DLQ."
  }
}

run "tunnel_no_alb_public_egress" {
  command = plan
  variables {
    enable_alb             = false
    workload_public_ip     = true
    certificate_arn        = null
    alb_ingress_cidrs      = []
    gateway_readiness_path = null
    gateway_cloudflared = {
      image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/cloudflared@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:111122223333:repository/cloudflared"
      token_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:test-tunnel-abcdef"
    }
  }
  assert {
    condition     = length(aws_lb.gateway) == 0 && length(aws_vpc_security_group_ingress_rule.gateway_alb) == 0 && module.gateway.service_name != null
    error_message = "No ALB may exist in the public egress tunnel mode."
  }
}

run "no_alb_requires_connector" {
  command = plan
  variables {
    enable_alb = false
  }
  expect_failures = [var.gateway_cloudflared]
}

# Opt-ins off: the composed Gateway and Core container inputs must be exactly the origin/main shape.
run "default_containers_match_origin" {
  command = plan

  assert {
    condition = alltrue([
      jsonencode(output.gateway_container_environment) == jsonencode({
        PLATFORM_GATEWAY_PORT            = "8080"
        PLATFORM_GATEWAY_MANAGEMENT_PORT = "9091"
        PLATFORM_GATEWAY_AUTH_URI        = "http://test-dev-core.dev.internal:8081"
      }),
      jsonencode(output.gateway_container_secrets) == jsonencode({}),
      jsonencode(output.core_container_environment) == jsonencode({ PLATFORM_CORE_PORT = "8081" }),
      jsonencode(output.core_container_secrets) == jsonencode({}),
    ])
    error_message = "With dev_dual_auth disabled the Gateway and Core container inputs must match origin/main."
  }
}

run "dev_dual_auth_enabled_plans_with_secret_arns" {
  command = plan
  variables {
    carelog_enrollment_origin = "https://carelog.dev.internal"
    gateway_runtime = merge(var.gateway_runtime, {
      environment = {
        PLATFORM_GATEWAY_CARELOG_RAG_URI  = "http://carelog-rag.dev.internal:8080"
        PLATFORM_GATEWAY_CARELOG_BE_URI   = "http://dev-carelog.dev.internal:8080"
        PLATFORM_GATEWAY_REDIS_HOST       = "platform-valkey.dev.internal"
        PLATFORM_GATEWAY_REDIS_PORT       = "6379"
        PLATFORM_GATEWAY_REDIS_KEY_PREFIX = "platform:gateway:"
      }
      secrets = {
        PLATFORM_GATEWAY_INTERNAL_SECRET         = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/gateway-internal-AbCdEf"
        PLATFORM_GATEWAY_JWT_VERIFICATION_SECRET = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-reference-signing-AbCdEf"
      }
    })
    core_runtime = merge(var.core_runtime, {
      environment = {
        PLATFORM_IDENTITY_REDIS_HOST     = "platform-valkey.dev.internal"
        PLATFORM_IDENTITY_REDIS_PORT     = "6379"
        PLATFORM_IDENTITY_DATASOURCE_URL = "jdbc:postgresql://platform-db.dev.internal:5432/platform"
      }
      secrets = {
        PLATFORM_IDENTITY_DATASOURCE_USERNAME = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/platform-db-user-AbCdEf"
        PLATFORM_IDENTITY_DATASOURCE_PASSWORD = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/platform-db-password-AbCdEf"
        PLATFORM_IDENTITY_JWT_SECRET_KEY      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/platform-jwt-AbCdEf"
      }
    })
    dev_dual_auth = {
      enabled                            = true
      redis_tls_enabled                  = false
      jwt_signing_key_secret_arn         = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-reference-signing-AbCdEf"
      finance_trusted_context_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-trusted-context-AbCdEf"
      carelog_enrollment_secret_arn      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog-enrollment-AbCdEf"
      product_claims_secret_arn          = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog-claims-AbCdEf"
    }
  }
  assert {
    condition     = module.core.service_name != null && module.gateway.service_name != null
    error_message = "DEV dual-auth must plan both services with the same Core and Gateway topology."
  }
  assert {
    condition     = output.core_container_environment["PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL"] == "https://carelog.dev.internal" && output.core_container_environment["PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL"] == "https://carelog.dev.internal"
    error_message = "Core must call Carelog at the origin only; Core appends /api/v1 itself."
  }
  assert {
    condition     = output.gateway_container_environment["PLATFORM_GATEWAY_CARELOG_BE_URI"] == "http://dev-carelog.dev.internal:8080"
    error_message = "dual-auth must not override the Gateway Carelog backend; the gateway_runtime value stays authoritative."
  }
  assert {
    condition     = output.core_container_environment["SPRING_PROFILES_ACTIVE"] == "finance-reference,dev" && output.core_container_environment["PLATFORM_IDENTITY_REDIS_TLS_ENABLED"] == "false"
    error_message = "Core dual-auth profile and Redis TLS flag must come from the opt-in."
  }
}

run "dev_dual_auth_requires_secret_arns" {
  command = plan
  variables {
    carelog_enrollment_origin = "https://carelog.dev.internal"
    dev_dual_auth = {
      enabled                    = true
      redis_tls_enabled          = true
      jwt_signing_key_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-reference-signing-AbCdEf:key::"
    }
  }
  expect_failures = [var.dev_dual_auth]
}

run "dev_dual_auth_requires_redis_tls_setting" {
  command = plan
  variables {
    carelog_enrollment_origin = "https://carelog.dev.internal"
    dev_dual_auth = {
      enabled                            = true
      jwt_signing_key_secret_arn         = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-reference-signing-AbCdEf"
      finance_trusted_context_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-trusted-context-AbCdEf"
      carelog_enrollment_secret_arn      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog-enrollment-AbCdEf"
      product_claims_secret_arn          = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog-claims-AbCdEf"
    }
  }
  expect_failures = [var.dev_dual_auth]
}

run "dev_dual_auth_requires_gateway_runtime_keys" {
  command = plan
  variables {
    carelog_enrollment_origin = "https://carelog.dev.internal"
    core_runtime = merge(var.core_runtime, {
      environment = {
        PLATFORM_IDENTITY_REDIS_HOST     = "platform-valkey.dev.internal"
        PLATFORM_IDENTITY_REDIS_PORT     = "6379"
        PLATFORM_IDENTITY_DATASOURCE_URL = "jdbc:postgresql://platform-db.dev.internal:5432/platform"
      }
      secrets = {
        PLATFORM_IDENTITY_DATASOURCE_USERNAME = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/platform-db-user-AbCdEf"
        PLATFORM_IDENTITY_DATASOURCE_PASSWORD = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/platform-db-password-AbCdEf"
        PLATFORM_IDENTITY_JWT_SECRET_KEY      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/platform-jwt-AbCdEf"
      }
    })
    dev_dual_auth = {
      enabled                            = true
      redis_tls_enabled                  = false
      jwt_signing_key_secret_arn         = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-reference-signing-AbCdEf"
      finance_trusted_context_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/finance-trusted-context-AbCdEf"
      carelog_enrollment_secret_arn      = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog-enrollment-AbCdEf"
      product_claims_secret_arn          = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog-claims-AbCdEf"
    }
  }
  # Empty gateway_runtime from the file-level fixture.
  expect_failures = [var.gateway_runtime]
}

run "carelog_origin_rejects_path" {
  command = plan
  variables {
    carelog_enrollment_origin = "https://carelog.dev.internal/api"
  }
  expect_failures = [var.carelog_enrollment_origin]
}

run "carelog_origin_rejects_userinfo_and_query" {
  command = plan
  variables {
    carelog_enrollment_origin = "https://user@carelog.dev.internal?x=1"
  }
  expect_failures = [var.carelog_enrollment_origin]
}

run "carelog_origin_rejects_non_http_scheme" {
  command = plan
  variables {
    carelog_enrollment_origin = "ftp://carelog.dev.internal"
  }
  expect_failures = [var.carelog_enrollment_origin]
}
