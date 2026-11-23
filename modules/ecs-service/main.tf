data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}
resource "aws_iam_role" "app" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}
data "aws_iam_policy_document" "execution" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = tolist(setunion(toset([var.ecr_repository_arn]), var.additional_ecr_repository_arns))
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.service.arn}:*"]
  }
  dynamic "statement" {
    for_each = length(var.execution_secret_arns) > 0 ? [1] : []
    content {
      actions   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
      resources = tolist(var.execution_secret_arns)
    }
  }
  dynamic "statement" {
    for_each = length(var.execution_kms_key_arns) > 0 ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = tolist(var.execution_kms_key_arns)
    }
  }
}
resource "aws_iam_role_policy" "execution" {
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}
resource "aws_iam_role_policy" "app" {
  count  = var.app_policy_json == null ? 0 : 1
  role   = aws_iam_role.app.id
  policy = var.app_policy_json
}
resource "aws_security_group" "service" {
  name        = var.name
  description = "Private tasks for ${var.name}"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = var.tags
}
resource "aws_service_discovery_service" "service" {
  name = var.name
  dns_config {
    namespace_id = var.namespace_id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }
  health_check_custom_config {}
  tags = var.tags
}
resource "aws_ecs_task_definition" "baseline" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.app.arn
  skip_destroy             = true
  lifecycle { create_before_destroy = true }
  dynamic "volume" {
    for_each = var.additional_volume_names
    content { name = volume.value }
  }
  container_definitions = jsonencode(concat([merge({
    name             = var.name
    image            = var.image
    essential        = true
    stopTimeout      = 120
    portMappings     = var.app_port_mappings == null ? [{ containerPort = var.container_port, protocol = "tcp" }] : var.app_port_mappings
    mountPoints      = var.app_mount_points
    dependsOn        = var.app_container_dependencies
    environment      = [for key in sort(keys(var.environment)) : { name = key, value = var.environment[key] }]
    secrets          = [for key in sort(keys(var.secrets)) : { name = key, valueFrom = var.secrets[key] }]
    healthCheck      = { command = var.health_check.command, interval = var.health_check.interval, timeout = var.health_check.timeout, retries = var.health_check.retries, startPeriod = var.health_check.start_period }
    logConfiguration = { logDriver = "awslogs", options = { awslogs-group = aws_cloudwatch_log_group.service.name, awslogs-region = var.region, awslogs-stream-prefix = "app" } }
  }, length(var.app_mount_points) > 0 ? { mountPoints = var.app_mount_points } : {}, length(var.app_container_dependencies) > 0 ? { dependsOn = var.app_container_dependencies } : {})], var.additional_containers))
  tags = var.tags
}
resource "aws_ecs_service" "service" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = coalesce(var.first_task_definition_arn, aws_ecs_task_definition.baseline.arn)
  desired_count                      = var.desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = var.health_check_grace_period_seconds
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }
  service_registries { registry_arn = aws_service_discovery_service.service.arn }
  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]
    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }
  depends_on = [aws_iam_role_policy.execution, aws_iam_role_policy.app]
  lifecycle { ignore_changes = [task_definition, desired_count] }
  tags = var.tags
}
