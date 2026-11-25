# DEV-only dual-auth wiring. Every map below is empty unless var.dev_dual_auth.enabled, so the default plan is unchanged.
# Values follow the integration E2E (platform-infra 9248971, run 45533488756). Guards live in platform-services f9adfd3.
# Pinned constants: the Gateway guard requires issuer/audience/purpose/skew/lifetime exactly as below, and its
# maximum token lifetime (300) must equal the Core access-token TTL.
locals {
  dual_auth_on = var.dev_dual_auth.enabled

  core_dual_env = local.dual_auth_on ? {
    SPRING_PROFILES_ACTIVE                                           = "finance-reference,dev"
    PLATFORM_ENVIRONMENT                                             = "dev"
    PLATFORM_IDENTITY_AUTH_ENABLED                                   = "true"
    PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED                      = "true"
    PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED               = "true"
    PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED        = "true"
    PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_ISSUER                   = "urn:ranikunlabs:identity:finance:reference"
    PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_AUDIENCE                 = "finance-journal-reference"
    PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_ACCESS_TOKEN_TTL_SECONDS = "300"
    PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED                   = "true"
    PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED                     = "true"
    PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL                    = var.carelog_private_base_url
    PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED                         = "true"
    PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL                        = var.carelog_private_base_url
    PLATFORM_IDENTITY_REDIS_TLS_ENABLED                              = tostring(var.dev_dual_auth.redis_tls_enabled)
  } : {}

  core_dual_secrets = local.dual_auth_on ? {
    PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_SIGNING_KEY = var.dev_dual_auth.jwt_signing_key_secret_arn
    PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL     = var.dev_dual_auth.carelog_enrollment_secret_arn
    PLATFORM_IDENTITY_PRODUCT_CLAIMS_SERVICE_SECRET     = var.dev_dual_auth.product_claims_secret_arn
  } : {}

  gateway_dual_env = local.dual_auth_on ? {
    SPRING_PROFILES_ACTIVE                                        = "finance-trusted-context-reference"
    PLATFORM_ENVIRONMENT                                          = "dev"
    PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED                 = "true"
    PLATFORM_GATEWAY_CARELOG_BE_URI                               = var.carelog_private_base_url
    PLATFORM_GATEWAY_FINANCE_BE_URI                               = "http://${var.dev_dual_auth.finance_service_name}.${var.namespace_name}:${var.dev_dual_auth.finance_container_port}"
    PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED              = "false"
    PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED                    = "true"
    PLATFORM_GATEWAY_FINANCE_REFERENCE_ISSUER                     = "urn:ranikunlabs:identity:finance:reference"
    PLATFORM_GATEWAY_FINANCE_REFERENCE_AUDIENCE                   = "finance-journal-reference"
    PLATFORM_GATEWAY_FINANCE_REFERENCE_PURPOSE                    = "access"
    PLATFORM_GATEWAY_FINANCE_REFERENCE_CLOCK_SKEW_SECONDS         = "30"
    PLATFORM_GATEWAY_FINANCE_REFERENCE_MAX_TOKEN_LIFETIME_SECONDS = "300"
    PLATFORM_GATEWAY_REDIS_TLS_ENABLED                            = tostring(var.dev_dual_auth.redis_tls_enabled)
  } : {}

  gateway_dual_secrets = local.dual_auth_on ? {
    PLATFORM_GATEWAY_FINANCE_REFERENCE_JWT_VERIFICATION_KEY = var.dev_dual_auth.jwt_signing_key_secret_arn
    PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET = var.dev_dual_auth.finance_trusted_context_secret_arn
  } : {}
}
