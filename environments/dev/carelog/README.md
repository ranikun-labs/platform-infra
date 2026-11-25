# carelog DEV root

This root owns only the carelog service and its gateway ingress rule. Supply `shared` and `gateway_security_group_id` from reviewed shared/platform outputs; it does not read another state. Supply the expected 12-digit `aws_account_id`; the provider refuses credentials for a different account. Configure an existing encrypted state bucket and region with `terraform init -backend-config=...`; the key is fixed per root and S3 native locking is enabled. Bootstrap and authorize that bucket separately.

Supply the immutable ECR image digest, exact repository ARN, task sizing, actual listening port, health command, environment and ECS secret references for the `carelog-be` application. Do not put secret values in environment or Terraform variables/state; `secrets` maps container environment names to ECS-supported Secrets Manager/SSM references. `execution_secret_arns` must include the exact underlying secret/parameter ARNs (without ECS JSON-key suffixes) and `execution_kms_key_arns` any customer-managed decryption keys. App IAM is empty unless an explicitly scoped policy is supplied. Confirm the image contains the health-check command and handles SIGTERM gracefully before deployment. No product queue or cache dependency is assumed. Supply approved application runtime configuration and secret references; do not assume a shared authentication configuration. Finance trusted routing remains disabled until its actual contract is reviewed and configured.

Terraform creates a baseline task definition; `baseline_task_definition_arn` identifies it. At first creation the service uses it, unless a pre-registered `first_task_definition_arn` is provided. After creation, release automation owns the active service task definition and the scale controller owns desired count; Terraform ignores only those service fields. Terraform still registers a new baseline revision for task configuration changes, but does not deploy it automatically. The release process must compare its revision against the current baseline and explicitly deploy a matching revision whenever task settings change; otherwise the running service can retain stale settings despite a clean plan. Changes to IAM, discovery, network and service rollout remain Terraform-owned. Validate release/rollback and scaling ownership before enabling automation.

The initial desired count defaults to 0 for bootstrap; omit `runtime.initial_desired_count` or explicitly set it to 0. Supply this service security group ID to the shared root for its narrowly scoped database ingress and apply shared; only then start the service through the operational scale controller or manual procedure. Establish and verify the baseline of one task after networking and runtime configuration are ready. Shared owns database ingress; product roles must not mutate shared security groups.

Baseline revisions are retained across Terraform replacement and destroy. Release owners may deregister old revisions only after verifying that no service or other workload references them and the agreed rollback retention period has passed.

## carelog-be prod profile on DEV (enrollment and claims)

Source contract: `carelog-be` `origin/dev` `application-prod.yml`, `EnrollmentController`, `InternalIdentityClaimsController`. The root sets fixed flags in `main.tf` (`fixed_environment`), which override `runtime.environment`:

- `SPRING_PROFILES_ACTIVE=prod` (required; without it the prod YAML is not loaded)
- `CARELOG_IDENTITY_ENROLLMENT_ENABLED=true` (enables `PUT /api/v1/internal/v1/identity/carelog/enrollments/{accountId}`)
- `CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED=true` (enables `GET /api/v1/internal/identity/claims/{accountId}`). Overrides the literal `false` in `application-prod.yml`. Note: `docs/operations/carelog-v1-container-foundation.md` says this flag stays `false` for non-cutover deployments. Confirm with the Identity owner before apply.
- `VALKEY_TLS_ENABLED=true`, `CARELOG_FLYWAY_ENABLED=false`, `SPRING_FLYWAY_ENABLED=false`, `CARELOG_ENVIRONMENT=dev`

### Secrets (references only)

`runtime.secrets` maps the container env name to a Secrets Manager or SSM ARN. Every reference must also be listed in `runtime.execution_secret_arns`, without a JSON-key suffix. Validation rejects a missing required key and a non-ARN value.

Required keys (names only):
- `SPRING_DATASOURCE_USERNAME`, `SPRING_DATASOURCE_PASSWORD`: RDS runtime role
- `JWT_SECRET_KEY`: existing Carelog JWT signing key (preserve current)
- `GATEWAY_INTERNAL_SECRET`: shared Gateway-to-Carelog secret
- `CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET`: Core enrollment Bearer secret (at least 32 chars, distinct from the gateway and claims secrets)
- `CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET`: Core claims secret (at least 32 chars, distinct from gateway)

Optional: `SPRING_DATA_REDIS_USERNAME`, `SPRING_DATA_REDIS_PASSWORD` (Valkey ACL, only if ACL is enabled on the cluster).

Required `runtime.environment` keys: `SPRING_DATASOURCE_URL` (RDS JDBC URL, no credentials), `REDIS_HOST`, `REDIS_PORT`, `CARELOG_CORS_ALLOWED_ORIGINS`, `JWT_ACCESS_TOKEN_VALIDITY`, `JWT_REFRESH_TOKEN_VALIDITY` (existing ms values).

### /run/secrets and /run/rds-ca.pem

- `runtime_config_mount = true` mounts an empty ephemeral task volume at `/run/secrets`. This satisfies `spring.config.import: configtree:/run/secrets/`, which is non-optional. The app reads secret values from env references, so no init container or file materialization is needed. Default is `false`, which is the module's current behavior; DEV boot needs `true`.
- `/run/rds-ca.pem` is hardcoded by `application-prod.yml` (`sslrootcert`). Platform cannot supply it without a runtime fetch or an init container. **Required carelog-be change (not made here):** in `carelog-be/Dockerfile` runtime stage, before `USER 10001:10001`, copy a pinned AWS RDS CA bundle to `/run/rds-ca.pem` (for example `COPY --chmod=0444 certs/rds-ca.pem /run/rds-ca.pem`, read-only, public, reviewed). Also `RUN mkdir -p /run/secrets`. Until that lands, DEV boot fails with `sslrootcert` missing and this root cannot fix it.

### Core-side network and values (for the Core/Finance lane)

Core reaches Carelog by Cloud Map name `dev-carelog.<namespace_name>` on port 8080 over HTTP inside the VPC, matching Gateway-to-Core today. Set `core_security_group_id` to Core's service security group ID to add the ingress rule.

- `PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL=http://dev-carelog.<namespace_name>:8080/api/v1`
  Auth: `Authorization: Bearer <same value as CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET>`. Do not send `X-Service-Id`, `X-Service-Secret`, `X-Gateway-Secret`, `X-User-Id`, `X-Organization-Id`, `X-Role` or `X-Public-Id` on this path; the filter returns 403.
- `PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL=http://dev-carelog.<namespace_name>:8080/api/v1`
  Auth: `X-Service-Id: platform-identity` and `X-Service-Secret: <same value as CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET>`.
- Verify path composition in the Core client (whether it appends `/api/v1` itself) before use. The context path is `/api/v1`.

### Open items

- HTTPS: Cloud Map gives plain HTTP. Private HTTPS needs one of: ACM Private CA with ECS Service Connect TLS (not provisioned here), or an internal ALB with a publicly trusted ACM certificate on a domain the project controls (needs a Route 53 private zone and domain). Until one is chosen, Bearer and claims secrets travel in cleartext on the private VPC, as Gateway-to-Core does today. This is a security decision for the owner.
- Secret ARNs and env values are supplied by the operator. This root does not create them.
- `CARELOG_ENVIRONMENT` is `dev` in this root (the carelog-be default is `production`).
