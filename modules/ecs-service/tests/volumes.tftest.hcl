mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  name                   = "test-dev-volumes"
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
  health_check           = { command = ["CMD", "/test"], interval = 30, timeout = 5, retries = 3, start_period = 30 }
  log_retention_days     = 7
  tags                   = {}
}

run "no_volumes_by_default" {
  command = plan

  assert {
    condition     = length(aws_ecs_task_definition.baseline.volume) == 0 && !contains(keys(jsondecode(aws_ecs_task_definition.baseline.container_definitions)[0]), "mountPoints")
    error_message = "Default input must not add mountPoints to the application container."
  }
}

run "declared_volume_is_mounted_read_only" {
  command = plan

  variables {
    volume_names     = ["runtime-config"]
    app_mount_points = [{ source_volume = "runtime-config", container_path = "/run/secrets" }]
  }

  assert {
    condition     = length(aws_ecs_task_definition.baseline.volume) == 1 && [for v in aws_ecs_task_definition.baseline.volume : v.name][0] == "runtime-config"
    error_message = "The task definition must declare the runtime-config volume."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.baseline.container_definitions)[0].mountPoints == [{ sourceVolume = "runtime-config", containerPath = "/run/secrets", readOnly = true }]
    error_message = "The application container must mount runtime-config read-only at /run/secrets."
  }
}
