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
