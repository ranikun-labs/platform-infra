output "service_name" { value = module.service.service_name }
output "service_arn" { value = module.service.service_arn }
output "security_group_id" { value = module.service.security_group_id }
output "discovery_service_arn" { value = module.service.discovery_service_arn }
output "baseline_task_definition_arn" { value = module.service.baseline_task_definition_arn }
output "task_role_arn" { value = module.service.task_role_arn }
# Core origin for BOTH enrollment and product claims (the TLS listener serves both paths). Scheme, host, port only.
# Null unless https_enrollment is set (namespace_name is required then).
output "carelog_private_https_origin" {
  value = local.tls_enabled ? "https://${local.tls_dns_name}:${local.tls_port}" : null
}
