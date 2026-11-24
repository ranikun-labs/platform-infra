# Core task definition inputs for the Carelog TLS candidate (enrollment and registration on the Core side).
#
# Key rules (messages name keys or gates only; values are never printed):
# - "Candidate on" = merged env flag PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED or
#   PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED is "true" (trimmed, case-insensitive).
# - Candidate OFF: the candidate environment is ignored; env, secrets and containers equal the live inputs
#   (plus PLATFORM_CORE_PORT, which the module always sets). The image is the live image unless
#   enrollment_core_candidate is set (then the V3 gate below applies).
# - Candidate ON, all-or-nothing (completeness gate): the pinned Core image, the trust-init container
#   (digest-pinned, same base as the Core image), the carelog-trust volume, the read-only app mount, the
#   dependsOn SUCCESS on the init container, the truststore JVM options, 'dev' in SPRING_PROFILES_ACTIVE,
#   and the enrollment Bearer secret reference must all be present. No TLS server bundle may be given to Core.
# - Candidate ON: SPRING_PROFILES_ACTIVE gets "dev" appended (comma list, trimmed, case-insensitive, no
#   duplicates). "prod" or "production" as a list element fails the plan (decision: prep-cert-secrets.md 12).
# - Candidate ON: JAVA_TOOL_OPTIONS keeps every live option and gets the private truststore options. A
#   truststore option that differs from ours (in the live or the candidate value), a duplicate with a
#   different value, or an option that disables certificate checks fails the plan (option keys only).
# - V3 gate (independent of the enrollment flag): when the Core image differs from the live image,
#   core_v3_db_change_approval must be given (documentation gate, not proof; see variables.tf).
locals {
  core_live_env    = var.core_runtime.environment
  core_tls_env_all = var.enrollment_tls_candidate.environment
  core_merged_raw  = merge(local.core_live_env, local.core_tls_env_all)

  core_enrollment_flag   = lower(trimspace(lookup(local.core_merged_raw, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED", "false"))) == "true"
  core_registration_flag = lower(trimspace(lookup(local.core_merged_raw, "PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED", "false"))) == "true"
  core_candidate_on      = local.core_enrollment_flag || local.core_registration_flag

  # Candidate environment only applies when the candidate is on.
  core_tls_env   = local.core_candidate_on ? local.core_tls_env_all : {}
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
  spring_value     = local.core_candidate_on ? join(",", local.spring_effective) : local.spring_live_raw

  # ---- JAVA_TOOL_OPTIONS ------------------------------------------------------------------------
  jto_key       = "JAVA_TOOL_OPTIONS"
  jto_live_raw  = lookup(local.core_live_env, local.jto_key, null)
  jto_tls_raw   = lookup(local.core_tls_env, local.jto_key, null)
  jto_live_opts = [for o in split(" ", local.jto_live_raw == null ? "" : local.jto_live_raw) : o if o != ""]
  jto_tls_opts  = [for o in split(" ", local.jto_tls_raw == null ? "" : local.jto_tls_raw) : o if o != ""]
  jto_required  = ["-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts", "-Djavax.net.ssl.trustStorePassword=changeit"]
  jto_wanted    = distinct(concat(local.jto_required, local.jto_tls_opts))
  # Trust keys; only exactly our options, or the JDK default store type, may appear with them.
  jto_trust_keys   = ["-Djavax.net.ssl.trustStore", "-Djavax.net.ssl.trustStorePassword", "-Djavax.net.ssl.trustStoreType"]
  jto_allowed_opts = concat(local.jto_required, ["-Djavax.net.ssl.trustStoreType=pkcs12", "-Djavax.net.ssl.trustStoreType=PKCS12"])
  jto_all_opts     = concat(local.jto_live_opts, local.jto_tls_opts)
  # Options whose key is a truststore key but whose value is not ours (live or candidate, including duplicates).
  jto_conflicts = [
    for o in local.jto_all_opts : split("=", o)[0]
    if contains(local.jto_trust_keys, split("=", o)[0]) && !contains(local.jto_allowed_opts, o)
  ]
  # Options that switch off certificate validation (name patterns; the JDK ignores unknown -D keys, so
  # these are refused by pattern, not by a list of JVM keys).
  jto_unsafe = [
    for o in local.jto_all_opts : split("=", o)[0]
    if can(regex("(?i)trustall|insecure|nosslverif|disablehostname|sslcontext=|trustmanager", o))
  ]
  jto_missing   = [for o in local.jto_wanted : o if !contains(local.jto_live_opts, o)]
  jto_effective = concat(local.jto_live_opts, local.jto_missing)
  jto_value     = local.core_candidate_on ? (length(local.jto_effective) == 0 ? null : join(" ", local.jto_effective)) : local.jto_live_raw

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

  # ---- Completeness of the candidate (all-or-nothing) -------------------------------------------
  trust_init_name = "carelog-trust-init"
  trust_volume    = "carelog-trust"
  trust_mount     = "/run/carelog-trust"
  trust_init_containers = [
    for c in var.enrollment_tls_candidate.containers : c
    if try(c.name, "") == local.trust_init_name
  ]
  trust_init_digest_ok = length([
    for c in local.trust_init_containers : c
    if can(regex("@sha256:[a-f0-9]{64}$", try(c.image, "")))
  ]) == 1
  trust_mount_ok = length([
    for m in var.enrollment_tls_candidate.app_mount_points : m
    if m.sourceVolume == local.trust_volume && m.containerPath == local.trust_mount && m.readOnly
  ]) >= 1
  trust_dependency_ok = length([
    for d in var.enrollment_tls_candidate.app_dependencies : d
    if d.containerName == local.trust_init_name && d.condition == "SUCCESS"
  ]) >= 1
  bundle_given_to_core = length([
    for a in var.enrollment_tls_candidate.secret_arns : a
    if can(regex("enrollment-tls/server-bundle", a))
  ]) > 0

  # ---- Core secret names the module will render (names only) ------------------------------------
  core_secret_names = sort(keys(merge(
    var.core_runtime.secrets,
    var.enrollment_secret_arn == null || !local.core_candidate_on ? {} : { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL = var.enrollment_secret_arn },
  )))
}

# Candidate ON: the candidate may not override live values, may not add an unsafe or conflicting option, and
# must use the pinned image when given. Messages carry key names only.
resource "terraform_data" "enrollment_candidate_guard" {
  count = (var.enrollment_core_candidate != null || length(keys(local.core_tls_env_all)) > 0) ? 1 : 0
  input = "enrollment-candidate"

  lifecycle {
    precondition {
      condition     = length(local.core_tls_overrides) == 0
      error_message = "TLS candidate would override live Core env values (names only): ${join(", ", local.core_tls_overrides)}"
    }
    precondition {
      condition     = !local.core_candidate_on || length(local.spring_prod_hits) == 0
      error_message = "SPRING_PROFILES_ACTIVE contains a production profile while the candidate is on (key name only; values are not printed)."
    }
    precondition {
      condition     = !local.core_candidate_on || length(local.jto_conflicts) == 0
      error_message = "JAVA_TOOL_OPTIONS (live or candidate) sets a truststore option that is not the private truststore, or sets one key twice with different values (option keys: ${join(", ", distinct(local.jto_conflicts))})."
    }
    precondition {
      condition     = !local.core_candidate_on || length(local.jto_unsafe) == 0
      error_message = "JAVA_TOOL_OPTIONS (live or candidate) contains an option that disables certificate checks (option keys: ${join(", ", distinct(local.jto_unsafe))})."
    }
    precondition {
      condition     = var.enrollment_core_candidate == null || local.core_image == local.pinned_candidate_core_image
      error_message = "The enrollment Core candidate image must be the pinned digest in core_env.tf (ranikun/platform/core, 8353cec4...)."
    }
  }
}

# Candidate ON: every piece must be present together. Missing any one fails with the piece named.
resource "terraform_data" "enrollment_completeness" {
  count = local.core_candidate_on ? 1 : 0
  input = "enrollment-completeness"

  lifecycle {
    precondition {
      condition     = var.enrollment_core_candidate != null
      error_message = "Enrollment on: enrollment_core_candidate (pinned Core image) is missing."
    }
    precondition {
      condition     = local.core_image == local.pinned_candidate_core_image
      error_message = "Enrollment on: Core application image is not the pinned enrollment-capable digest (8353cec4)."
    }
    precondition {
      condition     = length(local.trust_init_containers) == 1
      error_message = "Enrollment on: trust-init container (name carelog-trust-init) is missing from enrollment_tls_candidate.containers."
    }
    precondition {
      condition     = local.trust_init_digest_ok
      error_message = "Enrollment on: trust-init container image must be digest-pinned (repo@sha256:<64 hex>)."
    }
    precondition {
      condition     = contains(var.enrollment_tls_candidate.volume_names, local.trust_volume)
      error_message = "Enrollment on: volume carelog-trust is missing from enrollment_tls_candidate.volume_names."
    }
    precondition {
      condition     = local.trust_mount_ok
      error_message = "Enrollment on: app mount of carelog-trust at /run/carelog-trust (readOnly true) is missing."
    }
    precondition {
      condition     = local.trust_dependency_ok
      error_message = "Enrollment on: app dependency on carelog-trust-init with condition SUCCESS is missing."
    }
    precondition {
      condition     = alltrue([for r in local.jto_required : contains(local.jto_effective, r)])
      error_message = "Enrollment on: JAVA_TOOL_OPTIONS does not carry the private truststore options."
    }
    precondition {
      condition     = contains([for p in local.spring_effective : lower(p)], "dev")
      error_message = "Enrollment on: SPRING_PROFILES_ACTIVE does not contain dev."
    }
    precondition {
      condition     = var.enrollment_secret_arn != null
      error_message = "Enrollment on: enrollment Bearer secret reference (PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL) is missing (enrollment_secret_arn)."
    }
    precondition {
      condition     = contains(local.core_secret_names, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL")
      error_message = "Enrollment on: PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL is not in the Core secret references."
    }
    precondition {
      condition     = !local.bundle_given_to_core
      error_message = "The TLS server bundle must not be given to Core (enrollment_tls_candidate.secret_arns contains enrollment-tls/server-bundle)."
    }
  }
}

# V3 gate: the Core image differs from the live image. Documentation gate, not proof (see variables.tf).
resource "terraform_data" "core_v3_gate" {
  count = local.core_image != var.core_runtime.image ? 1 : 0
  input = "core-v3-gate"

  lifecycle {
    precondition {
      condition     = var.core_v3_db_change_approval != null
      error_message = "Core image differs from the live image: core_v3_db_change_approval is required (Flyway V3 runs at first start)."
    }
    precondition {
      condition     = var.core_v3_db_change_approval == null ? false : (length(trimspace(var.core_v3_db_change_approval.reference)) > 0 && !startswith(trimspace(var.core_v3_db_change_approval.reference), "REPLACE"))
      error_message = "core_v3_db_change_approval.reference is empty."
    }
    precondition {
      condition     = var.core_v3_db_change_approval == null ? false : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}", var.core_v3_db_change_approval.v3_state_checked_at))
      error_message = "core_v3_db_change_approval.v3_state_checked_at must be an ISO-8601 time (YYYY-MM-DDTHH:MM:SS...)."
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

output "core_task_inputs" {
  description = "Names and counts of the Core task definition inputs (no values)."
  value = {
    image                  = local.core_image
    candidate_on           = local.core_candidate_on
    env_names              = sort(keys(local.core_environment))
    secret_names           = local.core_secret_names
    container_names        = sort(concat([], [for c in var.enrollment_tls_candidate.containers : try(c.name, "")]))
    volume_names           = sort(tolist(var.enrollment_tls_candidate.volume_names))
    mount_count            = length(var.enrollment_tls_candidate.app_mount_points)
    dependency_count       = length(var.enrollment_tls_candidate.app_dependencies)
    execution_secret_count = length(setunion(var.core_runtime.execution_secret_arns, var.enrollment_tls_candidate.secret_arns, var.enrollment_secret_arn == null || !local.core_candidate_on ? toset([]) : toset([var.enrollment_secret_arn])))
  }
}
