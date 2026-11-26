mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

variables {
  aws_account_id           = "124495093425"
  aws_region               = "ap-northeast-2"
  github_oidc_provider_arn = "arn:aws:iam::124495093425:oidc-provider/token.actions.githubusercontent.com"
  state_bucket_name        = "ranikun-dev-tfstate-124495093425"
}

run "trust_is_exact_environment_and_workflow" {
  command = plan
  assert {
    condition = length([for c in data.aws_iam_policy_document.trust.statement[0].condition : c if c.test == "StringEquals" && c.variable == "token.actions.githubusercontent.com:sub" && contains(c.values, "repo:ranikun-labs/platform-infra:environment:dev-signup-off-plan")]) == 1
    error_message = "Trust must bind the exact dev-signup-off-plan environment subject."
  }
  assert {
    condition = length([for c in data.aws_iam_policy_document.trust.statement[0].condition : c if c.test == "StringEquals" && c.variable == "token.actions.githubusercontent.com:job_workflow_ref" && contains(c.values, "ranikun-labs/platform-infra/.github/workflows/dev-signup-off-plan.yml@refs/heads/main")]) == 1
    error_message = "Trust must pin job_workflow_ref to the main workflow ref."
  }
  assert {
    condition     = aws_iam_role.plan.name == "ranikun-dev-signup-off-plan" && aws_iam_role.plan.max_session_duration == 3600
    error_message = "Role must keep its name and the IAM minimum session duration."
  }
}

run "state_lock_scope_is_exact" {
  command = plan
  assert {
    condition     = toset(one([for s in data.aws_iam_policy_document.plan.statement : s if s.sid == "ManageStateLockObjectsOnly"]).resources) == toset([for k in ["dev/carelog", "dev/platform", "dev/finance"] : "arn:aws:s3:::ranikun-dev-tfstate-124495093425/${k}/terraform.tfstate.tflock"])
    error_message = "Put/Delete must be limited to the three lock objects."
  }
  assert {
    condition     = toset(one([for s in data.aws_iam_policy_document.plan.statement : s if s.sid == "ReadNamedStateObjects"]).resources) == toset([for k in ["dev/carelog", "dev/platform", "dev/finance"] : "arn:aws:s3:::ranikun-dev-tfstate-124495093425/${k}/terraform.tfstate"])
    error_message = "GetObject must be limited to the three state keys."
  }
  assert {
    condition     = one([for s in data.aws_iam_policy_document.plan.statement : s if s.sid == "DenyStateObjectWrites"]).effect == "Deny"
    error_message = "State objects must have an explicit write deny."
  }
  assert {
    condition     = !contains(flatten([for s in data.aws_iam_policy_document.plan.statement : s.actions]), "secretsmanager:GetSecretValue") || one([for s in data.aws_iam_policy_document.plan.statement : s if s.sid == "DenySecretValuesAndChaining"]).effect == "Deny"
    error_message = "Secret values must be explicitly denied."
  }
}

run "no_kms_statement_by_default" {
  command = plan
  assert {
    condition     = length([for s in data.aws_iam_policy_document.plan.statement : s if s.sid == "StateCustomerKeyViaS3"]) == 0
    error_message = "KMS statement must be absent unless a state KMS key is supplied."
  }
}

run "reject_other_account_provider" {
  command = plan
  variables { github_oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/token.actions.githubusercontent.com" }
  expect_failures = [var.github_oidc_provider_arn]
}

run "reject_other_bucket" {
  command = plan
  variables { state_bucket_name = "ranikun-dev-tfstate-999999999999" }
  expect_failures = [var.state_bucket_name]
}

run "reject_other_region" {
  command = plan
  variables { aws_region = "us-east-1" }
  expect_failures = [var.aws_region]
}
