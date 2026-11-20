terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.24.0"
    }
  }
}

locals {
  task_definition_arn = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:task-definition/${var.service_name}:*"
  service_arn         = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:service/${var.cluster_name}/${var.service_name}"
  cluster_arn         = "arn:aws:ecs:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
}

data "aws_iam_policy_document" "trust" {
  for_each = toset(["publish", "deploy"])
  statement {
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
      values   = [var.github_oidc_subjects[each.key]]
    }
  }
}
resource "aws_ecr_repository" "service" {
  name                 = var.service_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration { scan_on_push = true }
  force_delete = false
  tags         = var.tags
}
resource "aws_iam_role" "publisher" {
  name               = "${var.service_name}-github-publisher"
  assume_role_policy = data.aws_iam_policy_document.trust["publish"].json
  tags               = var.tags
}
resource "aws_iam_role" "deployer" {
  name               = "${var.service_name}-github-deployer"
  assume_role_policy = data.aws_iam_policy_document.trust["deploy"].json
  tags               = var.tags
}
data "aws_iam_policy_document" "publisher" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:DescribeImages", "ecr:DescribeImageScanFindings", "ecr:BatchGetImage"]
    resources = [aws_ecr_repository.service.arn]
  }
}
resource "aws_iam_role_policy" "publisher" {
  role   = aws_iam_role.publisher.id
  policy = data.aws_iam_policy_document.publisher.json
}
data "aws_iam_policy_document" "deployer" {
  statement {
    actions   = ["ecs:DescribeServices"]
    resources = [local.service_arn]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
  }
  statement {
    actions   = ["ecs:UpdateService"]
    resources = [local.service_arn]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
    condition {
      test     = "ArnLike"
      variable = "ecs:task-definition"
      values   = [local.task_definition_arn]
    }
  }
  # DescribeTaskDefinition does not support resource-level permissions.
  statement {
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = [local.task_definition_arn]
  }
  statement {
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${var.aws_account_id}:role/${var.service_name}-execution",
      "arn:aws:iam::${var.aws_account_id}:role/${var.service_name}-task"
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "deployer" {
  role   = aws_iam_role.deployer.id
  policy = data.aws_iam_policy_document.deployer.json
}
output "ecr_repository_url" { value = aws_ecr_repository.service.repository_url }
output "ecr_repository_arn" { value = aws_ecr_repository.service.arn }
output "publisher_role_arn" { value = aws_iam_role.publisher.arn }
output "deployer_role_arn" { value = aws_iam_role.deployer.arn }
output "ecs_service_name" { value = var.service_name }
output "task_family" { value = var.service_name }
