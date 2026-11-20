mock_provider "aws" {}

variables {
  aws_region              = "ap-northeast-2"
  aws_account_id          = "111122223333"
  vpc_cidr                = "10.20.0.0/16"
  availability_zones      = ["ap-northeast-2a", "ap-northeast-2c"]
  public_subnet_cidrs     = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnet_cidrs    = ["10.20.10.0/24", "10.20.11.0/24"]
  database_engine_version = "16.6"
}

run "baseline" {
  command = plan

  assert {
    condition     = aws_rds_cluster.database.serverlessv2_scaling_configuration[0].min_capacity == 0.5 && aws_rds_cluster.database.serverlessv2_scaling_configuration[0].max_capacity == 2
    error_message = "Baseline uses nonzero minimum ACUs."
  }
  assert {
    condition     = !aws_rds_cluster_instance.database.publicly_accessible && aws_rds_cluster.database.storage_encrypted && aws_rds_cluster.database.deletion_protection && length(aws_vpc_security_group_ingress_rule.database) == 0
    error_message = "The DB must be private, protected and closed until explicit workload grants."
  }
}

run "optional_pause" {
  command = plan

  variables {
    database_min_capacity       = 0
    database_auto_pause_seconds = 300
  }

  assert {
    condition     = aws_rds_cluster.database.serverlessv2_scaling_configuration[0].min_capacity == 0 && aws_rds_cluster.database.serverlessv2_scaling_configuration[0].seconds_until_auto_pause == 300
    error_message = "Explicit 0 ACU enables the configured auto-pause interval."
  }
}
