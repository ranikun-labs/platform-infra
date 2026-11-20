mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
variables {
  aws_account_id           = "123456789012"
  aws_region               = "us-east-1"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  github_repository        = "ranikun-labs/carelog-be"
  cluster_name             = "dev-shared"
  service_name             = "dev-carelog"
  ecr_repository_name      = "ranikun/carelog/api"
  workload                 = "carelog"
  tags                     = {}
}
run "ecs_authorization" {
  command = plan
  assert {
    condition     = one([for s in data.aws_iam_policy_document.deployer.statement : s if contains(s.actions, "ecs:DescribeTaskDefinition")]).resources == toset(["*"])
    error_message = "DescribeTaskDefinition requires a wildcard resource."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.deployer.statement : s if contains(s.actions, "ecs:RegisterTaskDefinition")]).resources == toset(["arn:aws:ecs:us-east-1:123456789012:task-definition/dev-carelog:*"])
    error_message = "Registration must be restricted to the workload task family."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.deployer.statement : s if contains(s.actions, "ecs:UpdateService")]).resources == toset(["arn:aws:ecs:us-east-1:123456789012:service/dev-shared/dev-carelog"]) && length([for c in one([for s in data.aws_iam_policy_document.deployer.statement : s if contains(s.actions, "ecs:UpdateService")]).condition : c if c.test == "ArnLike" && c.variable == "ecs:task-definition" && toset(c.values) == toset(["arn:aws:ecs:us-east-1:123456789012:task-definition/dev-carelog:*"])]) == 1
    error_message = "Updates must target the exact service and permit only revisions of its family, including rollback revisions."
  }
}
