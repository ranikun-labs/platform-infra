output "service_name" { value = module.service.service_name }
output "service_arn" { value = module.service.service_arn }
output "security_group_id" { value = module.service.security_group_id }
output "discovery_service_arn" { value = module.service.discovery_service_arn }
output "baseline_task_definition_arn" { value = module.service.baseline_task_definition_arn }
output "task_role_arn" { value = module.service.task_role_arn }
# Core enrollment origin over the TLS sidecar. Host = Cloud Map name, which must be in the server certificate SAN.
# Null unless https_enrollment is set and shared.namespace_name is supplied.
output "carelog_private_https_origin" {
  value = !local.tls_enabled || var.shared.namespace_name == null ? null : "https://dev-carelog.${var.shared.namespace_name}:${local.tls_port}"
}

# Core-facing origin: scheme, host and port only. Core adapters append /api/v1/... themselves.
# Null until shared.namespace_name is supplied.
output "carelog_private_origin" {
  value = var.shared.namespace_name == null ? null : "http://dev-carelog.${var.shared.namespace_name}:${var.runtime.container_port}"
}
