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
