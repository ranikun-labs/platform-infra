# Core container env, SPRING_PROFILES_ACTIVE, JAVA_TOOL_OPTIONS and the enrollment-capable Core image.
# Offline (mock provider). Live Core fixture keys follow the live DEV task definition ranikun-platform-dev-core:3
# (names only; values are test fixtures). Each run states its full candidate input (no shared state).
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
    secrets                = {}
    execution_secret_arns  = []
    execution_kms_key_arns = []
    health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
    log_retention_days     = 7
  }
}

# ---- Enrollment OFF: the Core environment equals the live one --------------------------------------

run "disabled_env_equals_live" {
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
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_container_environment_names == sort(concat(keys(var.core_runtime.environment), ["PLATFORM_CORE_PORT"]))
    error_message = "Enrollment off: Core env names must equal the live names plus PLATFORM_CORE_PORT."
  }
  assert {
    condition     = output.core_spring_profiles_active == null && output.core_java_tool_options == null
    error_message = "Enrollment off: no SPRING_PROFILES_ACTIVE and no JAVA_TOOL_OPTIONS may be added."
  }
  assert {
    condition     = output.core_image_effective == var.core_runtime.image
    error_message = "Enrollment off and no candidate image: the live Core image is kept."
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
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
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
    error_message = "Enrollment off: live SPRING_PROFILES_ACTIVE must be unchanged."
  }
  assert {
    condition     = output.core_java_tool_options == "-XX:MaxRAMPercentage=75.0 -Djavax.net.ssl.trustStore=/etc/other"
    error_message = "Enrollment off: live JAVA_TOOL_OPTIONS must be unchanged (no truststore added)."
  }
}

# ---- Enrollment ON: SPRING_PROFILES_ACTIVE ---------------------------------------------------------

run "enabled_live_profiles_empty_becomes_dev" {
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
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_spring_profiles_active == "dev"
    error_message = "Enrollment on with no live profile: SPRING_PROFILES_ACTIVE must be dev."
  }
}

run "enabled_appends_dev_to_existing_profiles" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "a, b" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_spring_profiles_active == "a,b,dev"
    error_message = "Enrollment on: dev must be appended once to the existing comma list (trimmed)."
  }
}

run "enabled_dev_already_present_no_duplicate" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "DEV,a" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_spring_profiles_active == "DEV,a"
    error_message = "Enrollment on: an existing dev (any case) must not be duplicated or changed."
  }
}

run "enabled_dev_lowercase_last_no_duplicate" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = " a , dev " })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_spring_profiles_active == "a,dev"
    error_message = "Enrollment on: whitespace is trimmed and dev is not duplicated."
  }
}

run "enabled_prod_in_live_list_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "prod" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }
}

run "enabled_production_upper_case_in_list_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "a, PRODUCTION " })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }
}

run "enabled_prod_from_candidate_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true", SPRING_PROFILES_ACTIVE = "prod" }
      app_port_mappings   = []
    }
  }
}

run "enabled_substring_prod_is_not_a_production_profile" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { SPRING_PROFILES_ACTIVE = "preprod-like" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_spring_profiles_active == "preprod-like,dev"
    error_message = "Only whole list elements prod/production are refused, not substrings."
  }
}

# ---- Enrollment ON: JAVA_TOOL_OPTIONS --------------------------------------------------------------

run "enabled_jto_live_options_preserved_and_truststore_appended" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-XX:MaxRAMPercentage=75.0 -Dfoo=bar" })
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
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true"
        JAVA_TOOL_OPTIONS                            = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
      app_port_mappings = []
    }
  }

  assert {
    condition     = output.core_java_tool_options == "-XX:MaxRAMPercentage=75.0 -Dfoo=bar -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "Live JVM options must be kept in order and the truststore options appended once."
  }
}

run "enabled_jto_already_ours_no_duplicate" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "Options already equal to the truststore settings must not be duplicated."
  }
}

run "enabled_jto_pkcs12_type_is_accepted" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStoreType=pkcs12" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_java_tool_options == "-Djavax.net.ssl.trustStoreType=pkcs12 -Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
    error_message = "The JDK default store type pkcs12 is compatible with the produced store and must be kept."
  }
}

run "enabled_jto_other_truststore_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStore=/etc/other/cacerts" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }
}

run "enabled_jto_other_password_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStorePassword=other" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }
}

run "enabled_jto_jks_type_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { JAVA_TOOL_OPTIONS = "-Djavax.net.ssl.trustStoreType=JKS" })
    })
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }
}

# ---- Enrollment ON: env overrides and Core image ---------------------------------------------------

run "enabled_candidate_override_of_live_key_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true", PLATFORM_ENVIRONMENT = "staging" }
      app_port_mappings   = []
    }
  }
}

run "candidate_image_pinned_and_matching_base_is_used" {
  command = plan

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
    }
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_image_effective == "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
    error_message = "The candidate Core image must be the pinned 8353cec4 digest."
  }
}

run "candidate_image_not_pinned_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_candidate_guard]

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001"
    }
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "true" }
      app_port_mappings   = []
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
