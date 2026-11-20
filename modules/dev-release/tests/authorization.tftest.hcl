mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
variables {
  github_repository_owner_id = "211108135"
  github_repository_id       = "981081375"
  # Test fixture, not an assertion that Carelog's environment token was observed.
  github_oidc_subjects = {
    publish = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-publish"
    deploy  = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy"
  }

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

run "exact_environment_subjects" {
  command = plan
  assert {
    condition = alltrue([
      for operation in ["publish", "deploy"] :
      length(data.aws_iam_policy_document.trust[operation].statement) == 1 &&
      toset(one(data.aws_iam_policy_document.trust[operation].statement).actions) == toset(["sts:AssumeRoleWithWebIdentity"]) &&
      one([for c in one(data.aws_iam_policy_document.trust[operation].statement).condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).test == "StringEquals" &&
      toset(one([for c in one(data.aws_iam_policy_document.trust[operation].statement).condition : c if c.variable == "token.actions.githubusercontent.com:sub"]).values) == toset([var.github_oidc_subjects[operation]]) &&
      toset(one([for c in one(data.aws_iam_policy_document.trust[operation].statement).condition : c if c.variable == "token.actions.githubusercontent.com:aud"]).values) == toset(["sts.amazonaws.com"])
    ])
    error_message = "Trust must retain exact per-environment subjects, audience and web-identity action for both roles."
  }
}
run "reject_legacy_subject" {
  command = plan
  variables {
    github_oidc_subjects = { publish = "repo:ranikun-labs/carelog-be:environment:dev-carelog-publish", deploy = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy" }
  }
  expect_failures = [var.github_oidc_subjects]
}
run "reject_wildcard_subject" {
  command = plan
  variables {
    github_oidc_subjects = { publish = "repo:ranikun-labs@211108135/carelog-be@981081375:*", deploy = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy" }
  }
  expect_failures = [var.github_oidc_subjects]
}
run "reject_wrong_repository_id" {
  command = plan
  variables {
    github_oidc_subjects = { publish = "repo:ranikun-labs@211108135/carelog-be@1331151117:environment:dev-carelog-publish", deploy = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy" }
  }
  expect_failures = [var.github_oidc_subjects]
}
run "reject_wrong_environment" {
  command = plan
  variables {
    github_oidc_subjects = { publish = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy", deploy = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy" }
  }
  expect_failures = [var.github_oidc_subjects]
}
run "reject_empty_subject" {
  command = plan
  variables {
    github_oidc_subjects = { publish = "", deploy = "repo:ranikun-labs@211108135/carelog-be@981081375:environment:dev-carelog-deploy" }
  }
  expect_failures = [var.github_oidc_subjects]
}
