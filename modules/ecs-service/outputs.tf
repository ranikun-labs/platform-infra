output "service_name" { value = aws_ecs_service.service.name }
output "service_arn" { value = aws_ecs_service.service.id }
output "security_group_id" { value = aws_security_group.service.id }
output "discovery_service_arn" { value = aws_service_discovery_service.service.arn }
output "task_role_arn" { value = aws_iam_role.app.arn }
output "execution_role_arn" { value = aws_iam_role.execution.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.service.name }
output "baseline_task_definition_arn" { value = aws_ecs_task_definition.baseline.arn }
