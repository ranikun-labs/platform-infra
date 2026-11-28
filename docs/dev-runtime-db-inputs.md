# DEV Core and Carelog runtime database inputs

These fragments describe changes to private, complete runtime input files. They are not standalone Terraform variable files: `core_runtime` and `runtime` are objects, so a second assignment replaces the entire object. Copy the relevant entries into the existing reviewed objects while preserving all unrelated service configuration and secret references. Keep the completed files and plans private; use secret ARNs, never secret values. This candidate does not create database users, grant privileges, publish images, or apply infrastructure.

Before planning, provision separate least-privilege runtime database roles and Secrets Manager secrets for Core and Carelog through their approved database path. Each example assumes a JSON secret with `username` and `password` keys and uses ECS's JSON-key reference syntax. Replace all placeholders with verified values and include each underlying secret ARN, without a JSON-key suffix, in the corresponding `execution_secret_arns` set.

## Core (`environments/dev/platform`)

The following entries belong inside the existing `core_runtime` object. The endpoint must be the RDS hostname covered by its server certificate; use the actual database and schema established by the migration owner.

```hcl
environment = {
  # Preserve the other reviewed Core environment entries here.
  PLATFORM_IDENTITY_DATASOURCE_URL = "jdbc:postgresql://REPLACE_RDS_HOST:5432/REPLACE_DB?currentSchema=identity&sslmode=verify-full&sslrootcert=/etc/platform/rds-ca-bundle.pem"
  SPRING_FLYWAY_ENABLED             = "false"
  PLATFORM_IDENTITY_RUNTIME_ONLY    = "true"
}
secrets = {
  # Preserve unrelated reviewed Core secret references here.
  PLATFORM_IDENTITY_DATASOURCE_USERNAME = "arn:aws:secretsmanager:REGION:ACCOUNT:secret:CORE_RUNTIME_SECRET:username::"
  PLATFORM_IDENTITY_DATASOURCE_PASSWORD = "arn:aws:secretsmanager:REGION:ACCOUNT:secret:CORE_RUNTIME_SECRET:password::"
}
# Include arn:aws:secretsmanager:REGION:ACCOUNT:secret:CORE_RUNTIME_SECRET
# in execution_secret_arns along with ARNs still required by other references.
```

`/etc/platform/rds-ca-bundle.pem` is the proposed Core image contract, not a property Terraform supplies. Use this fragment only with a reviewed image that actually contains the pinned RDS CA at that path and permits the runtime user to read it. Rebuild and pin the Core trust-init image from this exact new Core image digest before using `core_truststore`; the existing trust-init image was built from an earlier Core digest. Remove `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_URL`, `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_USERNAME`, and `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_PASSWORD` from Core's runtime environment and secret map. Remove the former admin secret from `execution_secret_arns` only when no remaining container reference needs it, including any rollback revision that must still start. Schema migration is a separate path; runtime Flyway remains disabled.

## Carelog (`environments/dev/carelog`)

The following entries belong inside the existing `runtime` object. The existing DEV configuration uses `currentSchema=carelog`; retain it only after preflight confirms the live migrated schema and runtime grants.

```hcl
environment = {
  # Preserve the other reviewed Carelog environment entries here.
  SPRING_DATASOURCE_URL = "jdbc:postgresql://REPLACE_RDS_HOST:5432/REPLACE_DB?currentSchema=carelog&sslmode=verify-full&sslrootcert=/run/rds-ca.pem"
  SPRING_FLYWAY_ENABLED                                   = "false"
  CARELOG_FLYWAY_ENABLED                                  = "false"
}
secrets = {
  # Preserve unrelated reviewed Carelog secret references here.
  SPRING_DATASOURCE_USERNAME = "arn:aws:secretsmanager:REGION:ACCOUNT:secret:CARELOG_RUNTIME_SECRET:username::"
  SPRING_DATASOURCE_PASSWORD = "arn:aws:secretsmanager:REGION:ACCOUNT:secret:CARELOG_RUNTIME_SECRET:password::"
}
# Include arn:aws:secretsmanager:REGION:ACCOUNT:secret:CARELOG_RUNTIME_SECRET
# in execution_secret_arns along with ARNs still required by other references.
```

Use a reviewed Carelog image containing the RDS CA at `/run/rds-ca.pem`. The explicit JDBC URL covers DEV profiles as well as the production profile; remove any conflicting Hikari `sslmode=require` override. Remove an old admin secret ARN from `execution_secret_arns` only after checking all remaining container references and rollback requirements. Verify the runtime role has the necessary schema usage, table DML and sequence privileges without DDL; use a separate migration role.

For each service, confirm the RDS hostname, schema, grants, secret references, image digest and CA bundle against the deployed environment. Generate and review a separate locked plan before activation, including the task-definition and execution-policy changes. Confirm hostname verification and application readiness with the selected image and runtime role before treating the configuration as operational.
