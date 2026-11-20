mock_provider "aws" {}

variables {
  aws_region              = "ap-northeast-2"
  aws_account_id          = "111122223333"
  vpc_cidr                = "10.20.0.0/16"
  availability_zones      = ["ap-northeast-2a", "ap-northeast-2c"]
  public_subnet_cidrs     = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnet_cidrs    = ["10.20.10.0/24", "10.20.11.0/24"]
  database_engine_version = "16.15"
}

run "baseline" {
  command = plan

  assert {
    condition     = aws_rds_cluster.database.serverlessv2_scaling_configuration[0].min_capacity == 0 && aws_rds_cluster.database.serverlessv2_scaling_configuration[0].max_capacity == 2 && aws_rds_cluster.database.serverlessv2_scaling_configuration[0].seconds_until_auto_pause == 300
    error_message = "DEV defaults must pause after five idle minutes and retain the 2 ACU cap."
  }
  assert {
    condition     = !aws_rds_cluster_instance.database.publicly_accessible && aws_rds_cluster.database.storage_encrypted && aws_rds_cluster.database.deletion_protection && length(aws_vpc_security_group_ingress_rule.database) == 0
    error_message = "The DB must be private, protected and closed until explicit workload grants."
  }
}

run "optional_warm_capacity" {
  command = plan

  variables {
    database_min_capacity = 0.5
  }

  assert {
    condition     = aws_rds_cluster.database.serverlessv2_scaling_configuration[0].min_capacity == 0.5
    error_message = "An explicit warm minimum must override the 0 ACU default."
  }
}
