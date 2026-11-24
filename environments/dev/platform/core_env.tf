# Core container settings for the Carelog TLS candidate (enrollment on the Core side).
#
# Rules (all key-name-only in messages; values are never printed):
# - Enrollment OFF (PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED not "true"): the candidate environment is
#   ignored; the Core environment equals the live one (plus PLATFORM_CORE_PORT, which the module always sets).
# - Enrollment ON: SPRING_PROFILES_ACTIVE gets "dev" appended to the EXISTING profiles (comma list, trimmed,
#   case-insensitive, no duplicates). "prod" or "production" in the existing or candidate list fails the plan.
#   Spring's implicit "default" profile is dropped when any profile is set. No default-profile config exists
#   in platform-core at the build commit (see prep-cert-secrets.md section 12), so nothing is lost.
# - Enrollment ON: JAVA_TOOL_OPTIONS keeps every existing option and gets the private truststore options
#   appended. A different trustStore, trustStorePassword or trustStoreType already present fails the plan
#   (the JVM uses the last -D value, so silent duplicates would hide the conflict; see section 12).
# - The Core image is the candidate digest when enrollment_core_candidate is set, else the live image.
#   The candidate digest must equal the pinned constant below and the trust-init base digest.
locals {
  core_live_env    = var.core_runtime.environment
  core_tls_env_all = var.enrollment_tls_candidate.environment

  # Enrollment is decided by the merged environment (the candidate may set the flag).
  core_enrollment_enabled = lower(trimspace(lookup(merge(local.core_live_env, local.core_tls_env_all), "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED", "false"))) == "true"

  # Candidate environment only applies when enrollment is on.
  core_tls_env   = local.core_enrollment_enabled ? local.core_tls_env_all : {}
  core_live_keys = keys(local.core_live_env)

  # ---- Core image -------------------------------------------------------------------------------
  pinned_candidate_core_image = "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
  core_image                  = var.enrollment_core_candidate == null ? var.core_runtime.image : var.enrollment_core_candidate.image

  # ---- SPRING_PROFILES_ACTIVE -------------------------------------------------------------------
  spring_key       = "SPRING_PROFILES_ACTIVE"
  spring_live_raw  = lookup(local.core_live_env, local.spring_key, null)
  spring_tls_raw   = lookup(local.core_tls_env, local.spring_key, null)
  spring_live_list = [for p in split(",", local.spring_live_raw == null ? "" : local.spring_live_raw) : trimspace(p) if trimspace(p) != ""]
  spring_tls_list  = [for p in split(",", local.spring_tls_raw == null ? "" : local.spring_tls_raw) : trimspace(p) if trimspace(p) != ""]
  spring_all       = concat(local.spring_live_list, local.spring_tls_list)
  spring_unique    = [for i, p in local.spring_all : p if !contains([for q in slice(local.spring_all, 0, i) : lower(q)], lower(p))]
  spring_prod_hits = [for p in local.spring_all : p if contains(["prod", "production"], lower(p))]
  spring_has_dev   = contains([for p in local.spring_unique : lower(p)], "dev")
  spring_effective = local.spring_has_dev ? local.spring_unique : concat(local.spring_unique, ["dev"])
  spring_value     = local.core_enrollment_enabled ? join(",", local.spring_effective) : local.spring_live_raw

  # ---- JAVA_TOOL_OPTIONS ------------------------------------------------------------------------
  jto_key       = "JAVA_TOOL_OPTIONS"
  jto_live_raw  = lookup(local.core_live_env, local.jto_key, null)
  jto_tls_raw   = lookup(local.core_tls_env, local.jto_key, null)
  jto_live_opts = [for o in split(" ", local.jto_live_raw == null ? "" : local.jto_live_raw) : o if o != ""]
  jto_tls_opts  = [for o in split(" ", local.jto_tls_raw == null ? "" : local.jto_tls_raw) : o if o != ""]
  jto_required  = ["-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts", "-Djavax.net.ssl.trustStorePassword=changeit"]
  jto_wanted    = distinct(concat(local.jto_required, local.jto_tls_opts))
  # Options allowed to coexist with the truststore settings: exactly ours, or the JDK default store type.
  jto_trust_keys   = ["-Djavax.net.ssl.trustStore", "-Djavax.net.ssl.trustStorePassword", "-Djavax.net.ssl.trustStoreType"]
  jto_allowed_type = ["-Djavax.net.ssl.trustStoreType=pkcs12", "-Djavax.net.ssl.trustStoreType=PKCS12"]
  jto_conflicts = [
    for o in local.jto_live_opts : split("=", o)[0]
    if contains(local.jto_trust_keys, split("=", o)[0]) && !contains(concat(local.jto_wanted, local.jto_allowed_type), o)
  ]
  jto_missing   = [for o in local.jto_wanted : o if !contains(local.jto_live_opts, o)]
  jto_effective = concat(local.jto_live_opts, local.jto_missing)
  jto_value     = local.core_enrollment_enabled ? (length(local.jto_effective) == 0 ? null : join(" ", local.jto_effective)) : local.jto_live_raw

  # ---- Environment merge ------------------------------------------------------------------------
  core_tls_overrides = [
    for k in keys(local.core_tls_env) : k
    if !contains([local.spring_key, local.jto_key], k) && contains(local.core_live_keys, k) && lookup(local.core_live_env, k, null) != lookup(local.core_tls_env, k, null)
  ]
  core_tls_added = {
    for k, v in local.core_tls_env : k => v
    if !contains([local.spring_key, local.jto_key], k) && !contains(local.core_live_keys, k)
  }

  core_environment = merge(
    local.core_live_env,
    { PLATFORM_CORE_PORT = "8081" },
    local.core_tls_added,
    local.spring_value == null ? {} : { (local.spring_key) = local.spring_value },
    local.jto_value == null ? {} : { (local.jto_key) = local.jto_value },
  )
}

# Guard: any failed precondition stops the plan. Only key names appear in messages.
resource "terraform_data" "enrollment_candidate_guard" {
  count = (var.enrollment_core_candidate != null || length(keys(local.core_tls_env_all)) > 0) ? 1 : 0
  input = "enrollment-candidate"

  lifecycle {
    precondition {
      condition     = length(local.core_tls_overrides) == 0
      error_message = "TLS candidate would override live Core env values (names only): ${join(", ", local.core_tls_overrides)}"
    }
    precondition {
      condition     = !local.core_enrollment_enabled || length(local.spring_prod_hits) == 0
      error_message = "SPRING_PROFILES_ACTIVE contains a production profile while enrollment is enabled (key name only; values are not printed)."
    }
    precondition {
      condition     = !local.core_enrollment_enabled || length(local.jto_conflicts) == 0
      error_message = "JAVA_TOOL_OPTIONS already sets a different truststore option while enrollment is enabled (option keys only: ${join(", ", distinct(local.jto_conflicts))})."
    }
    precondition {
      condition     = var.enrollment_core_candidate == null || local.core_image == local.pinned_candidate_core_image
      error_message = "The enrollment Core candidate image must be the pinned digest in core_env.tf (ranikun/platform/core, 8353cec4...)."
    }
  }
}

output "core_container_environment_names" {
  description = "Core container env key names after the candidate merge (no values)."
  value       = sort(keys(local.core_environment))
}

output "core_spring_profiles_active" {
  description = "Effective SPRING_PROFILES_ACTIVE for Core (null when unset). Profile names only."
  value       = lookup(local.core_environment, "SPRING_PROFILES_ACTIVE", null)
}

output "core_java_tool_options" {
  description = "Effective JAVA_TOOL_OPTIONS for Core (null when unset). Contains no credentials."
  value       = lookup(local.core_environment, "JAVA_TOOL_OPTIONS", null)
}

output "core_image_effective" {
  description = "Core container image digest reference the module renders."
  value       = local.core_image
}
