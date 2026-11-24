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

# Mirrors carelog.tfvars.example (single-bundle design). Placeholders are syntactically valid, not real ARNs.
# BUNDLE and ENROLLMENT below are literal ARNs in the test only; they are references, not secret values.
run "enrollment_candidate_app_env_and_port_mappings" {
  command = plan

  variables {
    enrollment_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-service-GhIjKl"
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = { SERVER_ADDRESS = "127.0.0.1", CARELOG_IDENTITY_ENROLLMENT_ENABLED = "true", SPRING_FLYWAY_ENABLED = "false" }
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"]
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = []
      containers = [{
        name             = "carelog-tls-proxy"
        image            = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential        = true
        portMappings     = [{ containerPort = 8080, protocol = "tcp" }, { containerPort = 8443, protocol = "tcp" }]
        mountPoints      = [{ sourceVolume = "carelog-tls", containerPath = "/run/carelog-tls", readOnly = false }]
        secrets          = [{ name = "TLS_BUNDLE_JSON", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf" }]
        logConfiguration = { logDriver = "awslogs", options = { awslogs-group = "/ecs/ranikun-carelog-dev-api", awslogs-region = "ap-northeast-2", awslogs-stream-prefix = "tls-proxy" } }
        healthCheck      = { command = ["CMD-SHELL", "kill -0 $(cat /run/nginx.pid) && nc -z 127.0.0.1 8080 && wget -q -T 3 -O /dev/null http://127.0.0.1:9180/healthz"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
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
    condition     = alltrue([for k in keys(output.app_environment) : !endswith(k, "SECRET") && !endswith(k, "PASSWORD")])
    error_message = "Plain app environment must not carry secret-named keys."
  }
}

run "single_bundle_secret_and_execution_references" {
  command = plan

  variables {
    enrollment_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-service-GhIjKl"
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = { SERVER_ADDRESS = "127.0.0.1", CARELOG_IDENTITY_ENROLLMENT_ENABLED = "true", SPRING_FLYWAY_ENABLED = "false" }
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"]
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = []
      containers = [{
        name         = "carelog-tls-proxy"
        image        = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential    = true
        portMappings = [{ containerPort = 8080, protocol = "tcp" }, { containerPort = 8443, protocol = "tcp" }]
        mountPoints  = [{ sourceVolume = "carelog-tls", containerPath = "/run/carelog-tls", readOnly = false }]
        secrets      = [{ name = "TLS_BUNDLE_JSON", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf" }]
        healthCheck  = { command = ["CMD-SHELL", "kill -0 $(cat /run/nginx.pid) && nc -z 127.0.0.1 8080 && wget -q -T 3 -O /dev/null http://127.0.0.1:9180/healthz"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
      }]
    }
  }

  # Exactly one proxy secret, named TLS_BUNDLE_JSON, as a bare ARN (no :key:: and no version suffix).
  assert {
    condition     = length(output.proxy_secret_references) == 1 && output.proxy_secret_references["TLS_BUNDLE_JSON"] == "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"
    error_message = "The proxy must reference one bare bundle ARN as TLS_BUNDLE_JSON."
  }

  assert {
    condition     = !strcontains(output.proxy_secret_references["TLS_BUNDLE_JSON"], "::") && length(split(":", output.proxy_secret_references["TLS_BUNDLE_JSON"])) == 7
    error_message = "TLS_BUNDLE_JSON must not carry a json-key or version suffix."
  }

  # Execution role secrets added by this candidate: the bundle and the enrollment bearer secret, nothing else.
  assert {
    condition     = length(output.execution_secret_arns) == 2 && contains(output.execution_secret_arns, "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf") && contains(output.execution_secret_arns, "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-service-GhIjKl")
    error_message = "execution_secret_arns must contain only the bundle and the enrollment secret."
  }

  # The enrollment bearer secret reference is unchanged from the input it was given (baseline ARN above).
  assert {
    condition     = output.enrollment_secret_reference == "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-service-GhIjKl" && output.app_secret_references["CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET"] == output.enrollment_secret_reference
    error_message = "The enrollment secret must be referenced by the unchanged enrollment_secret_arn, as the app's CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET."
  }
}

run "proxy_healthcheck_contract" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = { SERVER_ADDRESS = "127.0.0.1", CARELOG_IDENTITY_ENROLLMENT_ENABLED = "true", SPRING_FLYWAY_ENABLED = "false" }
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:111122223333:repository/carelog-tls-proxy"]
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = []
      containers = [{
        name         = "carelog-tls-proxy"
        image        = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential    = true
        portMappings = [{ containerPort = 8080, protocol = "tcp" }, { containerPort = 8443, protocol = "tcp" }]
        mountPoints  = [{ sourceVolume = "carelog-tls", containerPath = "/run/carelog-tls", readOnly = false }]
        secrets      = [{ name = "TLS_BUNDLE_JSON", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf" }]
        healthCheck  = { command = ["CMD-SHELL", "kill -0 $(cat /run/nginx.pid) && nc -z 127.0.0.1 8080 && wget -q -T 3 -O /dev/null http://127.0.0.1:9180/healthz"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
      }]
    }
  }

  assert {
    condition     = output.proxy_health_check.command[0] == "CMD-SHELL" && output.proxy_health_check.startPeriod == 300 && output.proxy_health_check.interval == 30 && output.proxy_health_check.timeout == 10 && output.proxy_health_check.retries == 3
    error_message = "Proxy healthCheck must be CMD-SHELL with startPeriod 300 (covers the 161-179 s app start), interval 30, timeout 10, retries 3."
  }

  assert {
    condition     = strcontains(output.proxy_health_check.command[1], "127.0.0.1:9180/healthz") && strcontains(output.proxy_health_check.command[1], "nc -z 127.0.0.1 8080")
    error_message = "Proxy healthCheck must probe the loopback health route and the app listener."
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

# Negative cases: the validation rules in variables.tf must reject each shape.
run "rejects_json_key_bundle_arn" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = {}
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = []
      containers = [{
        name         = "carelog-tls-proxy"
        image        = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential    = true
        portMappings = []
        mountPoints  = []
        secrets      = [{ name = "TLS_BUNDLE_JSON", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf:tls_private_key::" }]
        healthCheck  = { command = ["CMD-SHELL", "true"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
      }]
    }
  }

  expect_failures = [var.enrollment_tls_candidate]
}

run "rejects_separate_cert_and_key_secrets" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = {}
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-cert-AbCdEf", "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-key-GhIjKl"]
      kms_key_arns        = []
      containers = [{
        name         = "carelog-tls-proxy"
        image        = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential    = true
        portMappings = []
        mountPoints  = []
        secrets      = [{ name = "TLS_CERT_PEM", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-cert-AbCdEf" }, { name = "TLS_KEY_PEM", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-key-GhIjKl" }]
        healthCheck  = { command = ["CMD-SHELL", "true"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
      }]
    }
  }

  expect_failures = [var.enrollment_tls_candidate]
}

run "rejects_short_healthcheck_start_period" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = {}
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = []
      containers = [{
        name         = "carelog-tls-proxy"
        image        = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential    = true
        portMappings = []
        mountPoints  = []
        secrets      = [{ name = "TLS_BUNDLE_JSON", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf" }]
        healthCheck  = { command = ["CMD-SHELL", "true"], interval = 30, timeout = 10, retries = 3, startPeriod = 30 }
      }]
    }
  }

  expect_failures = [var.enrollment_tls_candidate]
}

run "rejects_two_secret_arns" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-tls"]
      app_port_mappings   = []
      environment         = {}
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf", "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-ca-GhIjKl"]
      kms_key_arns        = []
      containers = [{
        name         = "carelog-tls-proxy"
        image        = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-tls-proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        essential    = true
        portMappings = []
        mountPoints  = []
        secrets      = [{ name = "TLS_BUNDLE_JSON", valueFrom = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf" }]
        healthCheck  = { command = ["CMD-SHELL", "true"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
      }]
    }
  }

  expect_failures = [var.enrollment_tls_candidate]
}
