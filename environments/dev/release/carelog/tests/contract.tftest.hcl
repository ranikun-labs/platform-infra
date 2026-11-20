mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
variables {
  aws_account_id           = "123456789012"
  aws_region               = "us-east-1"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  cluster_name             = "dev-shared"
}
run "release_contract" {
  command = plan
  assert {
    condition     = module.release["carelog"].ecs_service_name == "ranikun-carelog-dev-api"
    error_message = "The workload must use the service's existing name."
  }
}
run "reject_wrong_provider" {
  command = plan
  variables { github_oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/token.actions.githubusercontent.com" }
  expect_failures = [var.github_oidc_provider_arn]
}

run "ecr_name" {
  command = plan
  assert {
    condition = module.release["carelog"].ecr_repository_name == "ranikun/carelog/api"
    error_message = "ECR repository name mismatch."
  }
}
