# Core task definition inputs for the Carelog TLS candidate. Offline (mock provider).
# Live fixture keys follow the live DEV task definition ranikun-platform-dev-core:3 (names only; values are
# test fixtures). The file-level candidate is COMPLETE (enrollment on, pinned Core, trust-init, wiring, secret,
# V3 approval). Runs that need a different input state the whole input again.
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
    image              = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001"
    ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core"
    cpu                = 256
    memory             = 1024
    environment = {
      PLATFORM_IDENTITY_REDIS_HOST                 = "fixture.invalid"
      PLATFORM_IDENTITY_REDIS_TLS_ENABLED          = "true"
      PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL    = "http://ranikun-carelog-dev-api.dev.internal:8080"
      PLATFORM_IDENTITY_AUTH_ENABLED               = "true"
      PLATFORM_IDENTITY_REDIS_PORT                 = "6379"
      PLATFORM_IDENTITY_FLYWAY_DATASOURCE_URL      = "jdbc:postgresql://fixture.invalid:5432/app?sslmode=require"
      PLATFORM_IDENTITY_JWT_REFRESH_TOKEN_VALIDITY = "604800000"
      PLATFORM_IDENTITY_DATASOURCE_URL             = "jdbc:postgresql://fixture.invalid:5432/app?sslmode=require"
      PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED     = "true"
      PLATFORM_IDENTITY_REDIS_KEY_PREFIX           = "ranikun:dev"
      PLATFORM_ENVIRONMENT                         = "dev"
      PLATFORM_IDENTITY_JWT_ACCESS_TOKEN_VALIDITY  = "900000"
    }
    secrets = {
      PLATFORM_IDENTITY_JWT_SECRET_KEY = "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/shared-identity/jwt-ZJU32o:signing_key::"
    }
    execution_secret_arns  = ["arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/shared-identity/jwt-ZJU32o"]
    execution_kms_key_arns = []
    health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
    log_retention_days     = 7
  }
  enrollment_secret_arn      = "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-service-XXXXXX"
  core_trust_init_pinned_ref = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  enrollment_core_candidate = {
    image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
    trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
  }
  core_v3_db_change_approval = {
    reference           = "CHG-TEST-0001"
    v3_state_checked_at = "2026-11-24T10:00:00Z"
  }
  enrollment_tls_candidate = {
    volume_names        = ["carelog-trust"]
    containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
    app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
    app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
    ecr_repository_arns = []
    secret_arns         = []
    kms_key_arns        = []
    environment = {
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
      PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
      JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    }
    app_port_mappings = []
  }
}

# ---- Candidate OFF: inputs identical to live --------------------------------------------------------

run "disabled_inputs_identical_to_live" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_secret_arn      = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = {}
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_container_environment_names == sort(concat(keys(var.core_runtime.environment), ["PLATFORM_CORE_PORT"]))
    error_message = "Candidate off: env names must equal live plus PLATFORM_CORE_PORT."
  }
  assert {
    condition     = output.core_spring_profiles_active == null && output.core_java_tool_options == null
    error_message = "Candidate off: no SPRING_PROFILES_ACTIVE and no JAVA_TOOL_OPTIONS may be added."
  }
  assert {
    condition     = output.core_image_effective == var.core_runtime.image
    error_message = "Candidate off with no candidate image: the live image is kept."
  }
  assert {
    condition     = output.core_task_inputs.candidate_on == false && length(output.core_task_inputs.container_names) == 0 && length(output.core_task_inputs.volume_names) == 0
    error_message = "Candidate off: no extra containers or volumes."
  }
  assert {
    condition     = output.core_task_inputs.mount_count == 0 && output.core_task_inputs.dependency_count == 0
    error_message = "Candidate off: no app mounts or dependencies."
  }
  assert {
    condition     = length(output.core_task_inputs.secret_names) == 1 && contains(output.core_task_inputs.secret_names, "PLATFORM_IDENTITY_JWT_SECRET_KEY") && output.core_task_inputs.execution_secret_count == 1
    error_message = "Candidate off: Core secret references and execution secret ARNs must equal live."
  }
}

run "disabled_keeps_live_profiles_and_options_untouched" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, {
        SPRING_PROFILES_ACTIVE = "a,prod"
        JAVA_TOOL_OPTIONS      = "-XX:MaxRAMPercentage=75.0 -Djavax.net.ssl.trustStore=/etc/other"
      })
    })
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_secret_arn      = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = {}
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_spring_profiles_active == "a,prod"
    error_message = "Candidate off: live SPRING_PROFILES_ACTIVE must be unchanged."
  }
  assert {
    condition     = output.core_java_tool_options == "-XX:MaxRAMPercentage=75.0 -Djavax.net.ssl.trustStore=/etc/other"
    error_message = "Candidate off: live JAVA_TOOL_OPTIONS must be unchanged."
  }
}

run "disabled_candidate_image_needs_v3_approval" {
  command         = plan
  expect_failures = [terraform_data.core_v3_gate]

  variables {
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = {}
      app_port_mappings   = []
    }
  }
}

# ---- Candidate ON: complete input passes; each missing piece fails ----------------------------------

run "enabled_complete_input_passes" {
  command = plan

  assert {
    condition     = output.core_image_effective == var.enrollment_core_candidate.image
    error_message = "Candidate on: the pinned candidate Core image is rendered."
  }
  assert {
    condition     = output.core_task_inputs.candidate_on == true && contains(output.core_task_inputs.secret_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL")
    error_message = "Candidate on: the enrollment Bearer secret reference must be a Core secret."
  }
  assert {
    condition     = output.core_task_inputs.execution_secret_count == 2
    error_message = "Candidate on: the execution role must cover the live secret and the enrollment Bearer secret, and no TLS bundle."
  }
  assert {
    condition     = output.core_spring_profiles_active == "dev"
    error_message = "Candidate on with no live profile: SPRING_PROFILES_ACTIVE must be dev."
  }
  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "Candidate on: truststore options only when the live value is empty."
  }
}

run "enabled_missing_candidate_image_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_core_candidate = null
  }
}

run "enabled_missing_trust_init_container_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings = []
    }
  }
}

run "enabled_trust_init_not_digest_pinned_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness, terraform_data.core_trust_init_gate]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init:latest", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings = []
    }
  }
}

run "enabled_missing_volume_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings = []
    }
  }
}

run "enabled_mount_not_read_only_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings = []
    }
  }
}

run "enabled_missing_init_dependency_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings = []
    }
  }
}

run "enabled_missing_enrollment_secret_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_secret_arn = null
  }
}

run "enabled_tls_bundle_given_to_core_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = []
      environment = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
      PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings = []
    }
  }
}

run "enabled_registration_flag_alone_is_on" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_secret_arn = null
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true", JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" }
      app_port_mappings   = []
    }
  }
}

# ---- Candidate ON: SPRING_PROFILES_ACTIVE -----------------------------------------------------------

run "enabled_appends_dev_to_existing_profiles" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "a, b" })
    })
  }

  assert {
    condition     = output.core_spring_profiles_active == "a,b,dev"
    error_message = "Candidate on: dev must be appended once to the existing comma list (trimmed)."
  }
}

run "enabled_dev_already_present_no_duplicate" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "DEV,a" })
    })
  }

  assert {
    condition     = output.core_spring_profiles_active == "DEV,a"
    error_message = "Candidate on: an existing dev (any case) must not be duplicated or changed."
  }
}

run "enabled_dev_lowercase_last_no_duplicate" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = " a , dev " })
    })
  }

  assert {
    condition     = output.core_spring_profiles_active == "a,dev"
    error_message = "Candidate on: whitespace is trimmed and dev is not duplicated."
  }
}

run "enabled_prod_in_live_list_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "prod" })
    })
  }
}

run "enabled_production_upper_case_in_list_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "a, PRODUCTION " })
    })
  }
}

run "enabled_prod_from_candidate_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        SPRING_PROFILES_ACTIVE                         = "prod"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
      app_port_mappings = []
    }
  }
}

run "enabled_substring_prod_is_not_a_production_profile" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "preprod-like" })
    })
  }

  assert {
    condition     = output.core_spring_profiles_active == "preprod-like,dev"
    error_message = "Only whole list elements prod or production are refused, not substrings."
  }
}

# ---- Candidate ON: live JAVA_TOOL_OPTIONS ------------------------------------------------------------

run "enabled_jto_live_options_preserved_and_truststore_appended" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-XX:MaxRAMPercentage=75.0 -Dfoo=bar" })
    })
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }

  assert {
    condition     = output.core_java_tool_options == "-XX:MaxRAMPercentage=75.0 -Dfoo=bar -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "Live JVM options kept in order; the truststore options appended once."
  }
}

run "enabled_jto_already_ours_no_duplicate" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" })
    })
  }

  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "Options already equal to ours must not be duplicated."
  }
}

run "enabled_jto_pkcs12_type_is_accepted" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStoreType=pkcs12" })
    })
  }

  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStoreType=pkcs12 -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "The JDK default store type pkcs12 is compatible and must be kept."
  }
}

run "enabled_live_jto_other_truststore_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/etc/other/cacerts" })
    })
  }
}

run "enabled_live_jto_other_password_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStorePassword=other" })
    })
  }
}

run "enabled_live_jto_jks_type_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStoreType=JKS" })
    })
  }
}

# ---- Candidate ON: candidate-provided JAVA_TOOL_OPTIONS ---------------------------------------------

run "candidate_jto_other_truststore_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/tmp/other.jks"
      }
    })
  }
}

run "candidate_jto_other_password_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStorePassword=other"
      }
    })
  }
}

run "candidate_jto_same_key_twice_different_values_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStore=/etc/x.jks -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }
}

run "candidate_jto_trust_all_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustAll=true -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }
}

run "candidate_jto_trust_store_none_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=NONE"
      }
    })
  }
}

run "candidate_jto_revocation_toggle_is_allowed" {
  command = plan

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Dcom.sun.net.ssl.checkRevocation=false -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }

  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit -Dcom.sun.net.ssl.checkRevocation=false"
    error_message = "A revocation-check toggle is not a trust bypass and is kept."
  }
}

# ---- Candidate ON: overrides and Core image --------------------------------------------------------

run "enabled_candidate_override_of_live_key_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        PLATFORM_ENVIRONMENT                           = "staging"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }
}

run "enabled_candidate_image_not_pinned_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard, terraform_data.enrollment_completeness]

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001"
    }
  }
}

run "trust_init_base_mismatch_fails_validation" {
  command         = plan
  expect_failures = [var.enrollment_core_candidate]

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001"
    }
  }
}

run "candidate_image_tag_reference_fails_validation" {
  command         = plan
  expect_failures = [var.enrollment_core_candidate]

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core:latest"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core:latest"
    }
  }
}

# ---- V3 documentation gate ---------------------------------------------------------------------------

run "v3_candidate_without_approval_fails" {
  command         = plan
  expect_failures = [terraform_data.core_v3_gate]

  variables {
    core_v3_db_change_approval = null
  }
}

run "v3_empty_reference_fails" {
  command         = plan
  expect_failures = [terraform_data.core_v3_gate]

  variables {
    core_v3_db_change_approval = { reference = "  ", v3_state_checked_at = "2026-11-24T10:00:00Z" }
  }
}

run "v3_placeholder_reference_fails" {
  command         = plan
  expect_failures = [terraform_data.core_v3_gate]

  variables {
    core_v3_db_change_approval = { reference = "REPLACE_WITH_CHANGE_ID", v3_state_checked_at = "2026-11-24T10:00:00Z" }
  }
}

run "v3_bad_time_fails" {
  command         = plan
  expect_failures = [terraform_data.core_v3_gate]

  variables {
    core_v3_db_change_approval = { reference = "CHG-TEST-0001", v3_state_checked_at = "yesterday" }
  }
}

run "v3_candidate_with_approval_passes" {
  command = plan

  assert {
    condition     = output.core_image_effective == var.enrollment_core_candidate.image
    error_message = "Candidate with approval: the pinned image is rendered."
  }
}

run "v3_live_image_needs_no_approval" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_secret_arn      = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = {}
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_image_effective == var.core_runtime.image
    error_message = "Live image: no approval is required and the live image is kept."
  }
}
