mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name                   = "test-dev-gateway"
  region                 = "ap-northeast-2"
  cluster_arn            = "arn:aws:ecs:ap-northeast-2:111122223333:cluster/test-dev"
  vpc_id                 = "vpc-0123456789abcdef0"
  private_subnet_ids     = ["subnet-0123456789abcdef0"]
  namespace_id           = "ns-0123456789abcdef0"
  image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/gateway@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/gateway"
  container_port         = 8080
  cpu                    = 256
  memory                 = 512
  desired_count          = 0
  environment            = {}
  secrets                = {}
  execution_secret_arns  = []
  execution_kms_key_arns = []
  health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
  log_retention_days     = 7
  tags                   = {}
}

run "connector_is_opt_in" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.baseline.container_definitions)) == 1
    error_message = "A service without connector settings must keep only its application container."
  }
}

run "connector_uses_only_the_tunnel_secret_and_waits_for_gateway" {
  command = plan

  variables {
    assign_public_ip = true
    target_group_arn = null
    cloudflared = {
      image              = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/cloudflared@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      ecr_repository_arn = "arn:aws:ecr:ap-northeast-2:111122223333:repository/cloudflared"
      token_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111122223333:secret:test-tunnel-abcdef"
    }
  }

  assert {
    condition = aws_ecs_service.service.network_configuration[0].assign_public_ip && tolist(aws_ecs_service.service.network_configuration[0].subnets) == tolist(var.private_subnet_ids) && length(aws_ecs_service.service.load_balancer) == 0 && alltrue([
      for c in jsondecode(aws_ecs_task_definition.baseline.container_definitions) :
      c.name != "cloudflared" ? length(c.secrets) == 0 : (
        c.essential &&
        c.dependsOn[0].containerName == "test-dev-gateway" &&
        c.dependsOn[0].condition == "HEALTHY" &&
        length(c.secrets) == 1 &&
        c.secrets[0].name == "TUNNEL_TOKEN" &&
        c.secrets[0].valueFrom == var.cloudflared.token_secret_arn &&
        !contains(keys(c), "portMappings")
      )
    ]) && length(jsondecode(aws_ecs_task_definition.baseline.container_definitions)) == 2
    error_message = "The connector must wait for Gateway, use its dedicated token, and expose no port."
  }
}
