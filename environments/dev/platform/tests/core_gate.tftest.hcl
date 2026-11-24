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
  enrollment_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-service-XXXXXX"
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

# ---- Candidate inputs SET while the flags are false: nothing may reach the Core task definition -------
# Each run gives the complete candidate input (every piece set) with the enrollment and registration flags
# false (or absent), then asserts that the piece under test is absent from what the module receives.

run "off_whole_set_equals_baseline" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust", "carelog-extra"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = false }] }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy"]
      secret_arns         = ["arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"]
      kms_key_arns        = ["arn:aws:kms:ap-northeast-2:124495093425:key/11111111-2222-3333-4444-555555555555"]
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "false"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "false"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
        SPRING_PROFILES_ACTIVE                         = "dev"
      }
      app_port_mappings = [{ containerPort = 8443, protocol = "tcp" }]
    }
  }

  assert {
    condition     = output.core_task_inputs.env_names == sort(concat(keys(var.core_runtime.environment), ["PLATFORM_CORE_PORT"]))
    error_message = "Flags false: env names must equal the live names plus PLATFORM_CORE_PORT."
  }
  assert {
    condition     = output.core_task_inputs.secret_names == tolist(["PLATFORM_IDENTITY_JWT_SECRET_KEY"])
    error_message = "Flags false: Core secret references must equal live."
  }
  assert {
    condition     = output.core_task_inputs.exec_secret_arns == tolist(["arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/shared-identity/jwt-ZJU32o"]) && output.core_task_inputs.execution_secret_count == 1
    error_message = "Flags false: execution role secret ARNs must equal live."
  }
  assert {
    condition     = output.core_task_inputs.ecr_arns == tolist([var.core_runtime.ecr_repository_arn]) && length(output.core_task_inputs.additional_ecr_arns) == 0
    error_message = "Flags false: ECR ARNs must equal live (no additional repositories)."
  }
  assert {
    condition     = length(output.core_task_inputs.kms_arns) == 0
    error_message = "Flags false: no additional KMS key ARNs."
  }
  assert {
    condition     = length(output.core_task_inputs.volume_names) == 0 && output.core_task_inputs.mount_count == 0 && output.core_task_inputs.dependency_count == 0
    error_message = "Flags false: no volume, app mount or dependsOn."
  }
  assert {
    condition     = length(output.core_task_inputs.container_names) == 0 && output.core_task_inputs.additional_containers == 0
    error_message = "Flags false: no trust-init or other additional container."
  }
  assert {
    condition     = output.core_task_inputs.port_mapping_count == -1
    error_message = "Flags false: port mappings must stay at the module default (null)."
  }
  assert {
    condition     = output.core_spring_profiles_active == null && output.core_java_tool_options == null
    error_message = "Flags false: no dev profile and no truststore options, even with candidate values set."
  }
  assert {
    condition     = output.core_task_inputs.candidate_on == false
    error_message = "Flags false: the candidate must report off."
  }
}

run "off_no_enrollment_secret_reference" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names      = [], containers = [], app_mount_points = [], app_dependencies = [], ecr_repository_arns = [], secret_arns = [], kms_key_arns = []
      environment       = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings = []
    }
  }

  assert {
    condition     = !contains(output.core_task_inputs.secret_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL")
    error_message = "Flags false: the enrollment Bearer secret reference must not be a Core container secret."
  }
  assert {
    condition     = !contains(output.core_task_inputs.exec_secret_arns, var.enrollment_secret_arn)
    error_message = "Flags false: the enrollment secret ARN must not be in the execution role."
  }
}

run "off_no_trust_init_container" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false }]
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_task_inputs.additional_containers == 0 && length(output.core_task_inputs.container_names) == 0
    error_message = "Flags false: the trust-init container must not be rendered."
  }
}

run "off_no_carelog_trust_volume" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = length(output.core_task_inputs.volume_names) == 0
    error_message = "Flags false: the carelog-trust volume must not be rendered."
  }
}

run "off_no_app_mount_point" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_task_inputs.mount_count == 0
    error_message = "Flags false: no app mount point."
  }
}

run "off_no_init_dependency" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_task_inputs.dependency_count == 0
    error_message = "Flags false: no dependsOn on trust-init."
  }
}

run "off_no_additional_ecr_repository" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = ["arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init"]
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = length(output.core_task_inputs.additional_ecr_arns) == 0
    error_message = "Flags false: no additional ECR repository."
  }
}

run "off_no_additional_kms_key" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = ["arn:aws:kms:ap-northeast-2:124495093425:key/11111111-2222-3333-4444-555555555555"]
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = length(output.core_task_inputs.kms_arns) == 0
    error_message = "Flags false: no additional KMS key in the execution role."
  }
}

run "off_no_extra_env" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                             = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
        SPRING_PROFILES_ACTIVE                        = "dev"
      }
      app_port_mappings = []
    }
  }

  assert {
    condition     = !contains(output.core_task_inputs.env_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL") && !contains(output.core_task_inputs.env_names, "JAVA_TOOL_OPTIONS") && !contains(output.core_task_inputs.env_names, "SPRING_PROFILES_ACTIVE")
    error_message = "Flags false: no enrollment URL, truststore JVM option or dev profile may be rendered."
  }
}

run "off_no_port_mapping_override" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = []
      containers          = []
      app_mount_points    = []
      app_dependencies    = []
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = [{ containerPort = 8443, protocol = "tcp" }]
    }
  }

  assert {
    condition     = output.core_task_inputs.port_mapping_count == -1
    error_message = "Flags false: the candidate port mappings must not reach the Core task."
  }
}

run "off_candidate_image_switches_and_needs_v3_approval" {
  command         = plan
  expect_failures = [terraform_data.core_v3_gate]

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
    }
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }
}

run "off_candidate_image_with_approval_keeps_candidate_inputs_out" {
  command = plan

  variables {
    enrollment_core_candidate = {
      image                = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
      trust_init_core_base = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
    }
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false }]
      app_mount_points    = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }]
      app_dependencies    = [{ containerName = "carelog-trust-init", condition = "SUCCESS" }]
      ecr_repository_arns = []
      secret_arns         = []
      kms_key_arns        = []
      environment         = { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED = "false" }
      app_port_mappings   = []
    }
  }

  assert {
    condition     = output.core_image_effective == var.enrollment_core_candidate.image && output.core_task_inputs.candidate_on == false
    error_message = "Candidate image switch with the flag off: the pinned image is rendered and the candidate stays off."
  }
  assert {
    condition     = output.core_task_inputs.additional_containers == 0 && length(output.core_task_inputs.volume_names) == 0 && output.core_task_inputs.mount_count == 0 && output.core_task_inputs.dependency_count == 0
    error_message = "Candidate image switch with the flag off: no trust-init, volume, mount or dependsOn may leak in."
  }
  assert {
    condition     = !contains(output.core_task_inputs.secret_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL")
    error_message = "Candidate image switch with the flag off: no enrollment secret reference may leak in."
  }
}

run "off_live_image_needs_no_approval_and_no_candidate" {
  command = plan

  variables {
    enrollment_core_candidate  = null
    core_v3_db_change_approval = null
    enrollment_tls_candidate = {
      volume_names        = ["carelog-trust"]
      containers          = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false }]
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
    condition     = output.core_image_effective == var.core_runtime.image && output.core_task_inputs.additional_containers == 0
    error_message = "Live image with no candidate: the live image is kept and no candidate container is rendered."
  }
}

# ---- Candidate ON: each completeness piece on its own ----------------------------------------------

run "on_registration_flag_false_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "true"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "false"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }
}

run "on_enrollment_flag_false_with_registration_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = {
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED   = "false"
        PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED = "true"
        PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL  = "https://ranikun-carelog-dev-api.dev.internal:8443"
        JAVA_TOOL_OPTIONS                              = "-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
      }
    })
  }
}

run "on_auth_flag_absent_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = { for k, v in var.core_runtime.environment : k => v if k != "PLATFORM_IDENTITY_AUTH_ENABLED" }
    })
  }
}

run "on_auth_flag_false_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { PLATFORM_IDENTITY_AUTH_ENABLED = "false" })
    })
  }
}

run "on_persistence_flag_false_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = merge(var.core_runtime.environment, { PLATFORM_IDENTITY_PERSISTENCE_ENABLED = "false" })
    })
  }
}

run "on_persistence_flag_absent_passes" {
  command = plan

  variables {
    core_runtime = merge(var.core_runtime, {
      environment = { for k, v in var.core_runtime.environment : k => v if k != "PLATFORM_IDENTITY_PERSISTENCE_ENABLED" }
    })
  }

  assert {
    condition     = output.core_task_inputs.candidate_on == true
    error_message = "Persistence absent means enabled in the code: the candidate must pass."
  }
}

run "on_base_url_http_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "http://ranikun-carelog-dev-api.dev.internal:8443" })
    })
  }
}

run "on_base_url_wrong_port_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:443" })
    })
  }
}

run "on_base_url_path_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://ranikun-carelog-dev-api.dev.internal:8443/api" })
    })
  }
}

run "on_base_url_userinfo_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://user@ranikun-carelog-dev-api.dev.internal:8443" })
    })
  }
}

run "on_base_url_ip_literal_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://10.0.0.5:8443" })
    })
  }
}

run "on_base_url_public_host_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://example.com:8443" })
    })
  }
}

run "on_base_url_wildcard_or_whitespace_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = merge(var.enrollment_tls_candidate.environment, { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL = "https://*.dev.internal:8443 " })
    })
  }
}

run "on_base_url_missing_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      environment = { for k, v in var.enrollment_tls_candidate.environment : k => v if k != "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL" }
    })
  }
}

run "on_enrollment_secret_wrong_name_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-AbCdEf"
  }
}

run "on_enrollment_secret_placeholder_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_secret_arn = "REPLACE_WITH_ENROLLMENT_SECRET_ARN"
  }
}

run "on_enrollment_secret_empty_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_secret_arn = ""
  }
}

run "on_trust_init_own_mount_missing_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      containers = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false }]
    })
  }
}

run "on_trust_init_own_mount_read_only_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      containers = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/run/carelog-trust", readOnly = true }] }]
    })
  }
}

run "on_trust_init_own_mount_wrong_path_fails" {
  command         = plan
  expect_failures = [terraform_data.enrollment_completeness]

  variables {
    enrollment_tls_candidate = merge(var.enrollment_tls_candidate, {
      containers = [{ name = "carelog-trust-init", image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", essential = false, mountPoints = [{ sourceVolume = "carelog-trust", containerPath = "/tmp/trust", readOnly = false }] }]
    })
  }
}

run "on_complete_input_with_all_pieces_passes" {
  command = plan

  assert {
    condition     = output.core_task_inputs.candidate_on == true && output.core_task_inputs.additional_containers == 1 && output.core_task_inputs.mount_count == 1 && output.core_task_inputs.dependency_count == 1
    error_message = "Complete candidate input must render the init container, mount and dependency."
  }
  assert {
    condition     = contains(output.core_task_inputs.secret_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL") && contains(output.core_task_inputs.exec_secret_arns, var.enrollment_secret_arn)
    error_message = "Complete candidate input: the enrollment reference is in the container secrets and the execution role."
  }
}
