output "service_name" { value = module.service.service_name }
output "service_arn" { value = module.service.service_arn }
output "security_group_id" { value = module.service.security_group_id }
output "discovery_service_arn" { value = module.service.discovery_service_arn }
output "baseline_task_definition_arn" { value = module.service.baseline_task_definition_arn }
output "task_role_arn" { value = module.service.task_role_arn }

# Non-secret values the module receives for the app container (asserted in tests/).
output "app_environment" { value = local.app_environment }
output "app_port_mappings" { value = local.app_port_mappings }
output "proxy_health_check" { value = local.proxy_health_check }

# Secret REFERENCES (ARNs) only. Marked sensitive so plan output and test logs do not print ARNs.
output "app_secret_references" {
  value     = local.app_secret_references
  sensitive = true
}
output "proxy_secret_references" {
  value     = local.proxy_secret_references
  sensitive = true
}
output "execution_secret_arns" {
  value     = local.execution_secret_arns
  sensitive = true
}
output "enrollment_secret_reference" {
  value     = var.enrollment_secret_arn
  sensitive = true
}

# Candidate pieces the module receives (names and counts only), for the disabled-state regression tests.
output "candidate_container_names" { value = tolist([for c in var.enrollment_tls_candidate.containers : try(c.name, "")]) }
output "candidate_volume_names" { value = tolist(var.enrollment_tls_candidate.volume_names) }
output "candidate_additional_ecr_arns" { value = tolist(var.enrollment_tls_candidate.ecr_repository_arns) }
