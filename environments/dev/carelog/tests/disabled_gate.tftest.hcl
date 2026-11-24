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


# Regression: with no enrollment secret and no candidate input (the default), the Carelog task definition
# inputs equal the baseline: no proxy container, no TLS bundle, no extra execution permission, no 8443 rule.
run "disabled_default_equals_baseline" {
  command = plan

  assert {
    condition     = output.app_environment == var.runtime.environment
    error_message = "Disabled: app environment must equal the baseline runtime environment."
  }
  assert {
    condition     = length(output.candidate_container_names) == 0 && length(output.candidate_volume_names) == 0 && length(output.candidate_additional_ecr_arns) == 0
    error_message = "Disabled: no proxy container, volume or additional ECR repository may be rendered."
  }
  assert {
    condition     = length(output.proxy_secret_references) == 0 && output.enrollment_secret_reference == null
    error_message = "Disabled: no TLS bundle secret and no enrollment secret reference may be rendered."
  }
  assert {
    condition     = output.execution_secret_arns == toset(var.runtime.execution_secret_arns)
    error_message = "Disabled: execution role secret ARNs must equal the baseline (no extra permission)."
  }
  assert {
    condition     = output.app_port_mappings == null
    error_message = "Disabled: app port mappings stay at the module default."
  }
  assert {
    condition     = try(aws_vpc_security_group_ingress_rule.core_enrollment_tls[0].from_port, 0) != 8443
    error_message = "Disabled: no 8443 ingress rule from Core may exist."
  }
}

# Disabled as a whole-set comparison of the app container inputs (names only, sensitive values not printed).
run "disabled_whole_set_equals_baseline" {
  command = plan

  assert {
    condition     = keys(output.app_secret_references) == keys(var.runtime.secrets) && length(output.app_secret_references) == length(var.runtime.secrets)
    error_message = "Disabled: app secret references must equal the baseline set."
  }
  assert {
    condition     = output.proxy_health_check == null
    error_message = "Disabled: no proxy health check."
  }
}

# Known gap (documented, not a regression): the Carelog root has no enable switch. Candidate inputs that are
# set always reach the task definition, even without an enrollment secret. This run records that behaviour.
run "gap_candidate_containers_render_without_enrollment_secret" {
  command = plan

  variables {
    enrollment_secret_arn = null
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
        healthCheck  = { command = ["CMD-SHELL", "true"], interval = 30, timeout = 10, retries = 3, startPeriod = 300 }
      }]
    }
  }

  assert {
    condition     = output.candidate_container_names == tolist(["carelog-tls-proxy"])
    error_message = "Documented gap: the candidate container renders whenever it is set (no enable switch in the Carelog root)."
  }
}
