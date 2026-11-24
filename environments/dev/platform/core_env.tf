# Core container environment merge for the Carelog TLS candidate.
# Rule: the candidate may ADD keys, never override a live Core value. JAVA_TOOL_OPTIONS is the only
# key that is merged (live options first, then the truststore options). SPRING_PROFILES_ACTIVE may
# be set by the candidate only when live Core already sets it (live Core does not set it today).
# Only key NAMES appear in error messages; values are never printed.
locals {
  core_live_env      = var.core_runtime.environment
  core_tls_env_in    = var.enrollment_tls_candidate.environment
  core_tls_env_keys  = keys(local.core_tls_env_in)
  core_live_env_keys = keys(local.core_live_env)

  core_tls_overrides = [
    for k in local.core_tls_env_keys : k
    if k != "JAVA_TOOL_OPTIONS" && contains(local.core_live_env_keys, k) && lookup(local.core_live_env, k, null) != lookup(local.core_tls_env_in, k, null)
  ]
  core_tls_profile_adds = [
    for k in local.core_tls_env_keys : k
    if k == "SPRING_PROFILES_ACTIVE" && !contains(local.core_live_env_keys, k)
  ]
  core_tls_added = {
    for k, v in local.core_tls_env_in : k => v
    if k != "JAVA_TOOL_OPTIONS" && k != "SPRING_PROFILES_ACTIVE" && !contains(local.core_live_env_keys, k)
  }
  core_jto_parts         = compact([lookup(local.core_live_env, "JAVA_TOOL_OPTIONS", null), lookup(local.core_tls_env_in, "JAVA_TOOL_OPTIONS", null)])
  core_java_tool_options = length(local.core_jto_parts) == 0 ? null : join(" ", local.core_jto_parts)

  core_environment = merge(
    local.core_live_env,
    { PLATFORM_CORE_PORT = "8081" },
    local.core_tls_added,
    local.core_java_tool_options == null ? {} : { JAVA_TOOL_OPTIONS = local.core_java_tool_options },
  )
}

resource "terraform_data" "core_tls_env_guard" {
  count = length(local.core_tls_env_keys) > 0 ? 1 : 0
  input = "core-tls-env"

  lifecycle {
    precondition {
      condition     = length(local.core_tls_overrides) == 0
      error_message = "TLS candidate would override live Core env values (names only): ${join(", ", local.core_tls_overrides)}"
    }
    precondition {
      condition     = length(local.core_tls_profile_adds) == 0
      error_message = "TLS candidate must not add SPRING_PROFILES_ACTIVE when live Core does not set it."
    }
  }
}

output "core_container_environment_names" {
  description = "Core container env key names after the TLS candidate merge (no values)."
  value       = sort(keys(local.core_environment))
}

output "core_java_tool_options" {
  description = "Merged JAVA_TOOL_OPTIONS for Core (null when neither live nor candidate sets it)."
  value       = local.core_java_tool_options
}
