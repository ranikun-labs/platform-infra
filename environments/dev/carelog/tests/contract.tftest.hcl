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

# Opt-in off: the container must keep the pre-change shape exactly (only the operator's env and secrets, no mounts).
run "default_container_matches_baseline" {
  command = plan

  assert {
    condition     = jsondecode(module.service.baseline_container_definitions)[0].environment == [for k in sort(keys(var.runtime.environment)) : { name = k, value = var.runtime.environment[k] }]
    error_message = "With carelog_core_auth disabled the container environment must equal runtime.environment."
  }
  assert {
    condition     = jsondecode(module.service.baseline_container_definitions)[0].secrets == [for k in sort(keys(var.runtime.secrets)) : { name = k, valueFrom = var.runtime.secrets[k] }]
    error_message = "With carelog_core_auth disabled the container secrets must equal runtime.secrets."
  }
  assert {
    condition     = !contains(keys(jsondecode(module.service.baseline_container_definitions)[0]), "mountPoints") && length(aws_vpc_security_group_ingress_rule.core) == 0
    error_message = "With carelog_core_auth disabled there must be no /run/secrets mount and no Core ingress."
  }
}

run "core_auth_enabled_applies_prod_contract" {
  command = plan

  variables {
    carelog_core_auth = {
      enabled                = true
      valkey_tls_enabled     = true
      core_security_group_id = "sg-0123456789abcdef1"
    }
  }

  assert {
    condition = alltrue([
      contains(jsondecode(module.service.baseline_container_definitions)[0].environment, { name = "SPRING_PROFILES_ACTIVE", value = "prod" }),
      contains(jsondecode(module.service.baseline_container_definitions)[0].environment, { name = "VALKEY_TLS_ENABLED", value = "true" }),
      contains(jsondecode(module.service.baseline_container_definitions)[0].environment, { name = "CARELOG_IDENTITY_ENROLLMENT_ENABLED", value = "true" }),
      contains(jsondecode(module.service.baseline_container_definitions)[0].environment, { name = "CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED", value = "true" }),
    ])
    error_message = "Enabled Core auth must set the carelog-be prod profile contract."
  }
  assert {
    condition     = jsondecode(module.service.baseline_container_definitions)[0].mountPoints == [{ sourceVolume = "runtime-config", containerPath = "/run/secrets", readOnly = true }]
    error_message = "Enabled Core auth must mount runtime-config read-only at /run/secrets."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.core) == 1 && aws_vpc_security_group_ingress_rule.core[0].referenced_security_group_id == "sg-0123456789abcdef1" && aws_vpc_security_group_ingress_rule.core[0].from_port == 8080
    error_message = "Only the supplied Core security group may reach the product port through the Core rule."
  }
}

run "core_auth_requires_valkey_tls_and_core_sg" {
  command = plan

  variables {
    carelog_core_auth = { enabled = true }
  }
  expect_failures = [var.carelog_core_auth]
}

run "rejects_non_arn_core_sg" {
  command = plan

  variables {
    carelog_core_auth = { enabled = false, core_security_group_id = "not-a-sg" }
  }
  expect_failures = [var.carelog_core_auth]
}

run "core_auth_rejects_plaintext_secret_values" {
  command = plan

  variables {
    carelog_core_auth = { enabled = true, valkey_tls_enabled = true, core_security_group_id = "sg-0123456789abcdef1" }
    runtime = merge(var.runtime, {
      secrets = merge(var.runtime.secrets, { JWT_SECRET_KEY = "not-an-arn-plaintext-value" })
    })
  }

  expect_failures = [var.runtime]
}

run "core_auth_rejects_shared_enrollment_and_claims_secret" {
  command = plan

  variables {
    carelog_core_auth = { enabled = true, valkey_tls_enabled = true, core_security_group_id = "sg-0123456789abcdef1" }
    runtime = merge(var.runtime, {
      secrets = merge(var.runtime.secrets, {
        CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/enrollment"
      })
    })
  }

  expect_failures = [var.runtime]
}

run "private_origin_has_no_path" {
  command = plan

  variables {
    shared = merge(var.shared, { namespace_name = "dev.internal" })
  }

  assert {
    condition     = output.carelog_private_origin == "http://dev-carelog.dev.internal:8080"
    error_message = "Core must receive the origin only (scheme, host, port); Core appends /api/v1 itself."
  }
}

# Private HTTPS enrollment listener (TLS sidecar on 8443). Gated by carelog_core_auth; the app's 8080 mapping stays.
run "https_enrollment_sidecar_plans_listener" {
  command = plan

  variables {
    shared = merge(var.shared, { namespace_name = "dev.internal" })
    carelog_core_auth = {
      enabled                = true
      valkey_tls_enabled     = true
      core_security_group_id = "sg-0123456789abcdef1"
      https_enrollment = {
        proxy_image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ecr_repository_arn       = "arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"
        server_bundle_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/tls-bundle"
      }
    }
  }

  assert {
    condition     = output.carelog_private_https_origin == "https://dev-carelog.dev.internal:8443" && output.carelog_private_origin == "http://dev-carelog.dev.internal:8080"
    error_message = "HTTPS enrollment origin must use port 8443 with the Cloud Map host; the claims origin stays on the product port."
  }
  assert {
    condition     = length([for c in jsondecode(module.service.baseline_container_definitions) : c if c.name == "carelog-tls-proxy"]) == 1
    error_message = "The TLS sidecar container must be in the task definition."
  }
  assert {
    condition     = jsondecode(module.service.baseline_container_definitions)[0].portMappings == [{ containerPort = 8080, protocol = "tcp" }]
    error_message = "The app container keeps its 8080 mapping; the sidecar must not change the product port."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.core_enrollment_tls) == 1 && aws_vpc_security_group_ingress_rule.core_enrollment_tls[0].from_port == 8443 && aws_vpc_security_group_ingress_rule.core_enrollment_tls[0].referenced_security_group_id == "sg-0123456789abcdef1"
    error_message = "Only the Core security group may reach 8443."
  }
}

run "https_enrollment_requires_core_auth" {
  command = plan

  variables {
    carelog_core_auth = {
      enabled = false
      https_enrollment = {
        proxy_image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ecr_repository_arn       = "arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"
        server_bundle_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/tls-bundle"
      }
    }
  }
  expect_failures = [var.carelog_core_auth]
}

run "https_enrollment_rejects_unpinned_image" {
  command = plan

  variables {
    carelog_core_auth = {
      enabled                = true
      valkey_tls_enabled     = true
      core_security_group_id = "sg-0123456789abcdef1"
      https_enrollment = {
        proxy_image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy:latest"
        ecr_repository_arn       = "arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"
        server_bundle_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:dev/carelog/tls-bundle"
      }
    }
  }
  expect_failures = [var.carelog_core_auth]
}
