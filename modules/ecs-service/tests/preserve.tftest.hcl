# Preservation inputs. Defaults must equal the previous module behavior; live values must reach the resources.
# Real provider with fake credentials and no AWS calls: the trust policy is generated locally, so its JSON can be asserted.
provider "aws" {
  region                      = "ap-northeast-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111122223333"
  }
}

variables {
  name                   = "ranikun-test-dev-api"
  region                 = "ap-northeast-2"
  cluster_arn            = "arn:aws:ecs:ap-northeast-2:111122223333:cluster/test-dev"
  vpc_id                 = "vpc-0123456789abcdef0"
  private_subnet_ids     = ["subnet-0123456789abcdef0"]
  namespace_id           = "ns-0123456789abcdef0"
  image                  = "111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ecr_repository_arn     = "arn:aws:ecr:ap-northeast-2:111122223333:repository/app"
  container_port         = 8080
  cpu                    = 256
  memory                 = 512
  desired_count          = 0
  environment            = {}
  secrets                = {}
  execution_secret_arns  = []
  execution_kms_key_arns = []
  health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 300 }
  log_retention_days     = 7
  tags                   = {}
}

run "defaults_match_previous_behavior" {
  command = plan

  assert {
    condition     = aws_iam_role.execution.permissions_boundary == null && aws_iam_role.app.permissions_boundary == null
    error_message = "Without preservation inputs the roles must carry no permissions boundary."
  }
  assert {
    condition     = length(aws_service_discovery_service.service.health_check_custom_config) == 1
    error_message = "Main always declares the Cloud Map custom health check; the default must keep it."
  }
  assert {
    condition     = aws_ecs_service.service.network_configuration[0].assign_public_ip == false
    error_message = "Default tasks must not get a public IP."
  }
  assert {
    condition     = !strcontains(data.aws_iam_policy_document.assume.json, "aws:SourceAccount")
    error_message = "Default trust policy must not add source conditions."
  }
}

run "live_preserve_inputs_reach_resources" {
  command = plan

  variables {
    execution_permissions_boundary_arn    = "arn:aws:iam::111122223333:policy/dev-boundary-execution"
    task_permissions_boundary_arn         = "arn:aws:iam::111122223333:policy/dev-boundary-task"
    assume_role_source_conditions         = true
    service_discovery_custom_health_check = false
    assign_public_ip                      = true
  }

  assert {
    condition     = aws_iam_role.execution.permissions_boundary == "arn:aws:iam::111122223333:policy/dev-boundary-execution" && aws_iam_role.app.permissions_boundary == "arn:aws:iam::111122223333:policy/dev-boundary-task"
    error_message = "Each role must carry its own permissions boundary."
  }
  assert {
    condition     = strcontains(data.aws_iam_policy_document.assume.json, "aws:SourceAccount") && strcontains(data.aws_iam_policy_document.assume.json, "aws:SourceArn")
    error_message = "Trust policy must carry both source conditions when enabled."
  }
  assert {
    condition     = length(aws_service_discovery_service.service.health_check_custom_config) == 0
    error_message = "The custom health check block must be omitted when the input is false."
  }
  assert {
    condition     = aws_ecs_service.service.network_configuration[0].assign_public_ip == true
    error_message = "assign_public_ip must reach the service network configuration."
  }
}
