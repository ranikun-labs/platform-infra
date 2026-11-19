output "service_name" { value = module.service.service_name }
output "service_arn" { value = module.service.service_arn }
output "security_group_id" { value = module.service.security_group_id }
output "discovery_service_arn" { value = module.service.discovery_service_arn }
output "baseline_task_definition_arn" { value = module.service.baseline_task_definition_arn }
output "task_role_arn" { value = module.service.task_role_arn }
