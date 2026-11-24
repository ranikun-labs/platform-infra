# Core task definition inputs for the Carelog TLS candidate (enrollment and registration on the Core side).
#
# Key rules (messages name keys or gates only; values are never printed):
# - "Candidate on" = merged env flag PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED or
#   PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED is "true" (trimmed, case-insensitive).
# - Candidate OFF: the candidate inputs are NOT passed to the module at all (containers, volumes, mounts,
#   dependencies, ECR and KMS ARNs, secret ARNs, port mappings, env, enrollment secret). The task definition
#   inputs equal the live inputs plus PLATFORM_CORE_PORT (test: core_gate_regression.tftest.hcl).
# - The Core image is the candidate digest whenever enrollment_core_candidate is set, even with the flag off.
#   That independent switch requires the V3 documentation gate (core_v3_db_change_approval).
# - Candidate ON, all-or-nothing (completeness gate, enrollment_completeness): registration true, enrollment
#   true, Identity auth explicitly true, Identity persistence not disabled, the enrollment base URL exactly
#   https://<carelog_enrollment_host>:8443, a well-formed enrollment-service secret ARN referenced in the
#   container secrets and the execution role, the pinned Core image, the trust-init container (digest-pinned,
#   its own writable mount of carelog-trust at /run/carelog-trust), the app's read-only mount, dependsOn
#   SUCCESS, the truststore options and 'dev' in SPRING_PROFILES_ACTIVE. No TLS server bundle for Core.
# - Candidate ON: SPRING_PROFILES_ACTIVE gets "dev" appended (comma list, trimmed, case-insensitive, no
#   duplicates). "prod" or "production" as a list element fails the plan (decision: prep-cert-secrets.md 12).
# - Candidate ON: JAVA_TOOL_OPTIONS keeps every live option and gets the private truststore options. A
#   truststore option that differs from ours (live or candidate value), a duplicate with a different value,
#   or an option that disables certificate checks fails the plan (option keys only).
# - V3 gate (independent of the enrollment flag): when the Core image differs from the live image,
#   core_v3_db_change_approval must be given (documentation gate, not proof; variables.tf).
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
  # Options that switch off certificate validation (name patterns).
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

  # ---- Gated candidate inputs: the module receives them only when the candidate is on -----------
  core_gate_containers      = local.core_candidate_on ? var.enrollment_tls_candidate.containers : []
  core_gate_volumes         = local.core_candidate_on ? var.enrollment_tls_candidate.volume_names : toset([])
  core_gate_mounts          = local.core_candidate_on ? var.enrollment_tls_candidate.app_mount_points : []
  core_gate_deps            = local.core_candidate_on ? var.enrollment_tls_candidate.app_dependencies : []
  core_gate_ecr             = local.core_candidate_on ? var.enrollment_tls_candidate.ecr_repository_arns : toset([])
  core_gate_kms             = local.core_candidate_on ? var.enrollment_tls_candidate.kms_key_arns : toset([])
  core_gate_ports           = local.core_candidate_on ? var.enrollment_tls_candidate.app_port_mappings : null
  core_gate_secret_arns     = local.core_candidate_on ? var.enrollment_tls_candidate.secret_arns : toset([])
  core_enrollment_secret_on = local.core_candidate_on && var.enrollment_secret_arn != null
  core_gate_exec_enroll     = local.core_enrollment_secret_on ? toset([var.enrollment_secret_arn]) : toset([])
  core_secret_refs = merge(
    var.core_runtime.secrets,
    local.core_enrollment_secret_on ? { PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL = var.enrollment_secret_arn } : {},
  )
  core_exec_secret_arns = setunion(var.core_runtime.execution_secret_arns, local.core_gate_secret_arns, local.core_gate_exec_enroll)
  core_exec_kms_arns    = setunion(var.core_runtime.execution_kms_key_arns, local.core_gate_kms)

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
  # The init container mounts the volume itself, writable, at the same path.
  trust_init_own_mount_ok = length([
    for c in local.trust_init_containers : c
    if length([
      for m in try(c.mountPoints, []) : m
      if try(m.sourceVolume, "") == local.trust_volume && try(m.containerPath, "") == local.trust_mount && try(m.readOnly, true) == false
    ]) == 1
  ]) == 1
  trust_dependency_ok = length([
    for d in var.enrollment_tls_candidate.app_dependencies : d
    if d.containerName == local.trust_init_name && d.condition == "SUCCESS"
  ]) >= 1
  bundle_given_to_core = length([
    for a in var.enrollment_tls_candidate.secret_arns : a
    if can(regex("enrollment-tls/server-bundle", a))
  ]) > 0

  # Identity and enrollment settings, read from the merged environment (names only in messages).
  identity_auth_ok        = lower(trimspace(lookup(local.core_merged_raw, "PLATFORM_IDENTITY_AUTH_ENABLED", "false"))) == "true"
  identity_persistence_ok = lower(trimspace(lookup(local.core_merged_raw, "PLATFORM_IDENTITY_PERSISTENCE_ENABLED", "true"))) == "true"
  enrollment_base_url     = lookup(local.core_merged_raw, "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL", "")
  enrollment_base_expect  = "https://${var.carelog_enrollment_host}:8443"
  enrollment_base_url_ok  = local.enrollment_base_url == local.enrollment_base_expect
  enrollment_arn_ok = var.enrollment_secret_arn == null ? false : can(regex(
    "^arn:aws:secretsmanager:ap-northeast-2:[0-9]{12}:secret:ranikun/dev/carelog/enrollment-service-[A-Za-z0-9]{6}$",
    var.enrollment_secret_arn,
  ))
  enrollment_in_exec      = var.enrollment_secret_arn == null ? false : contains(local.core_exec_secret_arns, var.enrollment_secret_arn)
  enrollment_in_container = contains(keys(local.core_secret_refs), "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL")

  # Core secret names the module renders (names only).
  core_secret_names = sort(keys(local.core_secret_refs))
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

# Candidate ON: every piece must be present together. Missing or invalid pieces fail, each with its own message.
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
      condition     = local.core_registration_flag
      error_message = "Enrollment on: PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED must be true."
    }
    precondition {
      condition     = local.core_enrollment_flag
      error_message = "Enrollment on: PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED must be true."
    }
    precondition {
      condition     = local.identity_auth_ok
      error_message = "Enrollment on: PLATFORM_IDENTITY_AUTH_ENABLED must be explicitly true (the application default is false)."
    }
    precondition {
      condition     = local.identity_persistence_ok
      error_message = "Enrollment on: PLATFORM_IDENTITY_PERSISTENCE_ENABLED must not be false (absent means enabled in the code)."
    }
    precondition {
      condition     = local.enrollment_base_url_ok
      error_message = "Enrollment on: PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL must be exactly https://<carelog_enrollment_host>:8443 (no path, query, userinfo, whitespace, other port or host)."
    }
    precondition {
      condition     = local.enrollment_arn_ok
      error_message = "Enrollment on: enrollment_secret_arn must be the enrollment-service secret ARN (ranikun/dev/carelog/enrollment-service-<6 chars>)."
    }
    precondition {
      condition     = local.enrollment_in_container
      error_message = "Enrollment on: PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL is not in the Core container secret references."
    }
    precondition {
      condition     = local.enrollment_in_exec
      error_message = "Enrollment on: the enrollment Bearer secret ARN is not in the Core execution role secret ARNs."
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
      condition     = local.trust_init_own_mount_ok
      error_message = "Enrollment on: the trust-init container must mount carelog-trust at /run/carelog-trust with readOnly false (its own writable mount)."
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
      error_message = "core_v3_db_change_approval.reference is empty or a placeholder."
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
  description = "Everything the module receives for the Core task definition and execution role (names, ARNs and counts; no values)."
  value = {
    image                  = local.core_image
    candidate_on           = local.core_candidate_on
    env_names              = sort(keys(local.core_environment))
    secret_names           = local.core_secret_names
    exec_secret_arns       = sort(tolist(local.core_exec_secret_arns))
    ecr_arns               = sort(tolist(setunion(toset([var.core_runtime.ecr_repository_arn]), local.core_gate_ecr)))
    additional_ecr_arns    = sort(tolist(local.core_gate_ecr))
    kms_arns               = sort(tolist(local.core_exec_kms_arns))
    volume_names           = sort(tolist(local.core_gate_volumes))
    mount_points           = [for m in local.core_gate_mounts : "${m.sourceVolume}:${m.containerPath}:${m.readOnly ? "ro" : "rw"}"]
    dependencies           = [for d in local.core_gate_deps : "${d.containerName}:${d.condition}"]
    container_names        = sort([for c in local.core_gate_containers : try(c.name, "")])
    additional_containers  = length(local.core_gate_containers)
    port_mapping_count     = local.core_gate_ports == null ? -1 : length(local.core_gate_ports)
    mount_count            = length(local.core_gate_mounts)
    dependency_count       = length(local.core_gate_deps)
    execution_secret_count = length(local.core_exec_secret_arns)
  }
}
