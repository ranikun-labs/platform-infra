# Dedicated OFF-plan role for .github/workflows/dev-signup-off-plan.yml. Separate from ranikun-dev-shared-plan.
# Read-only for provider refresh; state read is limited to the carelog, platform and finance keys; the only
# writes are Terraform's <key>.tflock objects. Permissions are derived from the candidate root resource set
# (see docs/runbooks/dev-signup-off-plan-setup.ko.md, permission table).

locals {
  github_repository = "ranikun-labs/platform-infra"
  subject           = "repo:${local.github_repository}:environment:dev-signup-off-plan"
  job_workflow_ref  = "${local.github_repository}/.github/workflows/dev-signup-off-plan.yml@refs/heads/main"
  role_name         = "ranikun-dev-signup-off-plan"

  tags = merge(var.tags, { Environment = "dev", Owner = "platform", ManagedBy = "terraform" })

  bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"
  # Exact state keys of the roots this workflow plans. No other state is readable.
  state_keys        = ["dev/carelog/terraform.tfstate", "dev/platform/terraform.tfstate", "dev/finance/terraform.tfstate"]
  state_object_arns = [for k in local.state_keys : "${local.bucket_arn}/${k}"]
  lock_keys         = [for k in local.state_keys : "${k}.tflock"]
  lock_object_arns  = [for k in local.lock_keys : "${local.bucket_arn}/${k}"]

  regional_arn_prefix = "arn:aws:%s:${var.aws_region}:${var.aws_account_id}:%s"

  # Carelog and finance use dev-*; platform services use its name_prefix (ranikun-dev-gateway, ranikun-dev-core).
  workload_name_prefixes = ["dev-", "ranikun-dev-"]
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "GitHubOidcSignupOffPlan"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.subject]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = [local.job_workflow_ref]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = local.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600 # IAM minimum; the workflow requests 900 s per run.
  tags                 = local.tags
}

data "aws_iam_policy_document" "plan" {
  # --- Terraform state: exact keys only ---
  statement {
    sid       = "ReadNamedStateObjects"
    actions   = ["s3:GetObject"]
    resources = local.state_object_arns
  }
  statement {
    sid       = "ListOnlyNamedStateAndLocks"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = concat(local.state_keys, local.lock_keys)
    }
  }
  # Terraform native locking writes and removes <key>.tflock only.
  statement {
    sid       = "ManageStateLockObjectsOnly"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = local.lock_object_arns
  }
  statement {
    sid       = "DenyStateObjectWrites"
    effect    = "Deny"
    actions   = ["s3:PutObject*", "s3:DeleteObject*", "s3:RestoreObject"]
    resources = local.state_object_arns
  }
  dynamic "statement" {
    for_each = var.state_kms_key_arn == null ? [] : [var.state_kms_key_arn]
    content {
      sid       = "StateCustomerKeyViaS3"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [statement.value]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${var.aws_region}.amazonaws.com"]
      }
    }
  }

  # --- Provider refresh (read-only). Regional statements are bound to ap-northeast-2. ---
  statement {
    sid       = "EcsServiceRead"
    actions   = ["ecs:DescribeServices", "ecs:ListTagsForResource"]
    resources = [format(local.regional_arn_prefix, "ecs", "service/${var.cluster_name}/*")]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "EcsTaskDefinitionRead"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"] # DescribeTaskDefinition has no resource-level permissions.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "EcsTaskDefinitionTags"
    actions   = ["ecs:ListTagsForResource"]
    resources = [for p in local.workload_name_prefixes : format(local.regional_arn_prefix, "ecs", "task-definition/${p}*:*")]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid = "Ec2SecurityGroupRead"
    actions = [
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
    ]
    resources = ["*"] # Describe calls have no resource-level permissions.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid = "ElbRead"
    actions = [
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"] # Describe calls have no resource-level permissions.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "LogGroupDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"] # Listing is not reliably scoped by log-group ARN; reads are limited to the tag call below.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "LogGroupTags"
    actions   = ["logs:ListTagsForResource"]
    resources = [for p in local.workload_name_prefixes : format(local.regional_arn_prefix, "logs", "log-group:/ecs/${p}*")]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "ServiceDiscoveryRead"
    actions   = ["servicediscovery:GetService", "servicediscovery:ListTagsForResource"]
    resources = [format(local.regional_arn_prefix, "servicediscovery", "service/*")]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid = "AuditQueueRead"
    actions = [
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ListQueueTags",
    ]
    resources = [
      format(local.regional_arn_prefix, "sqs", "*-audit"),
      format(local.regional_arn_prefix, "sqs", "*-audit-dlq"),
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "AlarmRead"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["*"] # DescribeAlarms has no resource-level permissions.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid = "AuditAlarmTags"
    actions = [
      "cloudwatch:ListTagsForResource",
    ]
    resources = [
      format(local.regional_arn_prefix, "cloudwatch", "alarm:*-audit-dlq-visible"),
      format(local.regional_arn_prefix, "cloudwatch", "alarm:*-audit-message-age"),
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
  statement {
    sid       = "IamRoleAndInlinePolicyRead"
    actions   = ["iam:GetRole", "iam:ListRoleTags", "iam:GetRolePolicy"]
    resources = [for p in local.workload_name_prefixes : "arn:aws:iam::${var.aws_account_id}:role/${p}*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceAccount"
      values   = [var.aws_account_id]
    }
  }

  # --- Guardrails: explicit denies for secret values, role chaining, and write families. ---
  statement {
    sid    = "DenySecretValuesAndChaining"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:GetRandomPassword",
      "ssm:GetParameter*",
      "iam:PassRole",
      "sts:AssumeRole*",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "DenyWriteFamilies"
    effect = "Deny"
    actions = [
      "ec2:Create*", "ec2:Delete*", "ec2:Modify*", "ec2:Authorize*", "ec2:Revoke*", "ec2:Run*", "ec2:Terminate*",
      "ecs:Create*", "ecs:Update*", "ecs:Register*", "ecs:Deregister*", "ecs:Delete*", "ecs:Run*", "ecs:Start*", "ecs:Stop*", "ecs:Put*", "ecs:Tag*", "ecs:Untag*",
      "iam:Create*", "iam:Delete*", "iam:Update*", "iam:Put*", "iam:Attach*", "iam:Detach*", "iam:Tag*", "iam:Untag*", "iam:Add*", "iam:Remove*",
      "logs:Create*", "logs:Delete*", "logs:Put*", "logs:Tag*", "logs:Untag*", "logs:Associate*",
      "sqs:Send*", "sqs:Receive*", "sqs:Delete*", "sqs:Purge*", "sqs:Set*", "sqs:Change*", "sqs:Create*", "sqs:Tag*", "sqs:Untag*",
      "elasticloadbalancing:Create*", "elasticloadbalancing:Delete*", "elasticloadbalancing:Modify*", "elasticloadbalancing:Register*", "elasticloadbalancing:Deregister*", "elasticloadbalancing:Set*", "elasticloadbalancing:Add*", "elasticloadbalancing:Remove*",
      "cloudwatch:Put*", "cloudwatch:Delete*", "cloudwatch:Set*", "cloudwatch:Tag*", "cloudwatch:Untag*",
      "servicediscovery:Create*", "servicediscovery:Delete*", "servicediscovery:Update*", "servicediscovery:Tag*", "servicediscovery:Untag*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "signup-off-plan-read"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}
