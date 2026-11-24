# Core env merge for the Carelog TLS candidate. Offline (mock provider). Asserts live Core keys are
# kept, JAVA_TOOL_OPTIONS is appended (not replaced), and an override of a live key fails the plan.
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
  # Live-shaped Core environment (key names from the live DEV task definition :3). Values are test fixtures.
  core_runtime = {
    image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:111122223333:repository/core"
    cpu                = 256
    memory             = 1024
    environment = {
      PLATFORM_IDENTITY_REDIS_HOST                 = "fixture.invalid"
      PLATFORM_IDENTITY_REDIS_TLS_ENABLED          = "true"
      PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL    = "http://ranikun-carelog-dev-api.dev.internal:8080"
      PLATFORM_IDENTITY_AUTH_ENABLED               = "true"
      PLATFORM_IDENTITY_REDIS_PORT                 = "6379"
      PLATFORM_IDENTITY_JWT_REFRESH_TOKEN_VALIDITY = "604800000"
      PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED     = "true"
      PLATFORM_IDENTITY_REDIS_KEY_PREFIX           = "ranikun:dev"
      PLATFORM_IDENTITY_FLYWAY_DATASOURCE_URL      = "jdbc:postgresql://fixture.invalid:5432/app?sslmode=require"
      PLATFORM_IDENTITY_DATASOURCE_URL             = "jdbc:postgresql://fixture.invalid:5432/app?sslmode=require"
      PLATFORM_ENVIRONMENT                         = "dev"
      PLATFORM_IDENTITY_JWT_ACCESS_TOKEN_VALIDITY  = "900000"
    }
    secrets                = {}
    execution_secret_arns  = []
    execution_kms_key_arns = []
    health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
    log_retention_days     = 7
  }
}

run "candidate_disabled_names_equal_live_plus_port" {
  command = plan

  assert {
    condition     = output.core_container_environment_names == sort(concat(keys(var.core_runtime.environment), ["PLATFORM_CORE_PORT"]))
    error_message = "With the candidate disabled, Core env names must equal the live names plus PLATFORM_CORE_PORT."
  }
  assert {
    condition     = output.core_java_tool_options == null
    error_message = "With no live and no candidate JAVA_TOOL_OPTIONS, the merged value must stay unset."
  }
}

run "candidate_keeps_live_parts_and_appends_truststore" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-XX:MaxRAMPercentage=75.0" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = {
        JAVA_TOOL_OPTIONS                             = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED  = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443"
      }
      app_port_mappings = []
    }
  }

  assert {
    condition     = output.core_java_tool_options == "-XX:MaxRAMPercentage=75.0 -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "JAVA_TOOL_OPTIONS must keep the live options and append the truststore options."
  }
  assert {
    condition     = alltrue([for k in keys(var.core_runtime.environment) : contains(output.core_container_environment_names, k)])
    error_message = "Every live Core env key must survive the TLS candidate merge."
  }
  assert {
    condition     = contains(output.core_container_environment_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED") && contains(output.core_container_environment_names, "PLATFORM_CORE_PORT")
    error_message = "Candidate-only enrollment keys and PLATFORM_CORE_PORT must be present."
  }
}

run "candidate_without_live_jto_sets_truststore_only" {
  command = plan

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = {
        JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
      app_port_mappings = []
    }
  }

  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "Without a live JAVA_TOOL_OPTIONS only the truststore options may be set."
  }
}

run "override_of_live_key_fails" {
  command         = plan
  expect_failures = [terraform_data.core_tls_env_guard]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_ENVIRONMENT = "prod" }
      app_port_mappings   = []
    }
  }
}

run "adding_spring_profile_fails" {
  command         = plan
  expect_failures = [terraform_data.core_tls_env_guard]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { SPRING_PROFILES_ACTIVE = "dev" }
      app_port_mappings   = []
    }
  }
}
