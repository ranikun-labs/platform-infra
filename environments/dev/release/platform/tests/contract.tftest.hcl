mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
variables {
  permissions_boundaries = {
    gateway = { publish = "arn:aws:iam::123456789012:policy/dev-boundary/ranikun-platform-dev-gateway-github-publish", deploy = "arn:aws:iam::123456789012:policy/dev-boundary/ranikun-platform-dev-gateway-github-deploy" }
    core    = { publish = "arn:aws:iam::123456789012:policy/dev-boundary/ranikun-platform-dev-core-github-publish", deploy = "arn:aws:iam::123456789012:policy/dev-boundary/ranikun-platform-dev-core-github-deploy" }
  }
  # Test-only expected pattern; these are not observed minted application claims.
  github_oidc_subjects = {
    gateway = { publish = "repo:ranikun-labs@211108135/platform-services@1327477262:environment:dev-gateway-publish", deploy = "repo:ranikun-labs@211108135/platform-services@1327477262:environment:dev-gateway-deploy" }
    core    = { publish = "repo:ranikun-labs@211108135/platform-services@1327477262:environment:dev-core-publish", deploy = "repo:ranikun-labs@211108135/platform-services@1327477262:environment:dev-core-deploy" }
  }
  aws_account_id           = "123456789012"
  aws_region               = "us-east-1"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  cluster_name             = "dev-shared"
  name_prefix              = "ranikun-platform-dev"
}
run "release_contract" {
  command = plan
  assert {
    condition     = module.release["gateway"].ecs_service_name == "ranikun-platform-dev-gateway"
    error_message = "The workload must use the service's existing name."
  }
}
run "reject_wrong_provider" {
  command = plan
  variables { github_oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/token.actions.githubusercontent.com" }
  expect_failures = [var.github_oidc_provider_arn]
}

run "ecr_name_gateway" {
  command = plan
  assert {
    condition     = module.release["gateway"].ecr_repository_name == "ranikun/platform/gateway"
    error_message = "The ECR repository name must match the workload contract."
  }
}

run "ecr_name_core" {
  command = plan
  assert {
    condition     = module.release["core"].ecr_repository_name == "ranikun/platform/core"
    error_message = "The ECR repository name must match the workload contract."
  }
}
