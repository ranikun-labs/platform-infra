# Evidence: Flyway switches for the Carelog candidate task and DEV V9 status

Status: read-only evidence, 2026-11-24. AWS calls were describe/list/filter only (`ranikun-admin`, ap-northeast-2). No secret value was read, no DB connection was made, no write action was taken.
Sources: carelog-be at `5d6aa88cdf44d01ca07a8fa8265a8c7cb0c2a995` (image `sha256:2630045e…` source, extracted with `git archive` into a private scratch dir), `.github/workflows/dev-ecs-release.yml` in this worktree, and live ECS/CloudWatch/RDS metadata.

## 1. Property resolution (static, carelog-be 5d6aa88c)

| Source | File:line | Value | Effect |
| --- | --- | --- | --- |
| Base config | `carelog-be/src/main/resources/application.yml:16-17` | `spring.flyway.enabled: true` | Flyway on in every profile unless overridden. |
| Base config | `application.yml:21-22` | `baseline-on-migrate: ${FLYWAY_BASELINE_ON_MIGRATE:false}` | No automatic baseline. |
| Prod profile | `carelog-be/src/main/resources/application-prod.yml:20-22` | `spring.flyway.enabled: ${CARELOG_FLYWAY_ENABLED:false}`, `baseline-on-migrate: false` | Only applies when the `prod` profile is active. Default false. |
| Test profile | `carelog-be/src/test/resources/application-test.yml:5-6` | `enabled: true` | Tests only. |
| Schema guard | `application.yml` and `application-prod.yml` `jpa.hibernate.ddl-auto: validate` | `validate` | The app never creates tables. |

Resolution order (Spring Boot externalized configuration): an OS environment variable such as `SPRING_FLYWAY_ENABLED` is bound to `spring.flyway.enabled` through relaxed binding and outranks both `application.yml` and `application-prod.yml`. This is the standard Spring Boot precedence and was not executed here (no JDK on this host; carelog-be tests need Testcontainers and network).

Consequences:
- `SPRING_FLYWAY_ENABLED=false` gives `spring.flyway.enabled=false` whatever the profile and whatever `CARELOG_FLYWAY_ENABLED` says.
- Without `SPRING_FLYWAY_ENABLED`, the result depends on the profile. With `prod` active, `CARELOG_FLYWAY_ENABLED` (default false) decides. Without `prod` active, `application.yml:17` turns Flyway on, and `CARELOG_FLYWAY_ENABLED` has no effect at all. So the `SPRING_` variable is the one that holds if the profile is ever lost.
- `CARELOG_FLYWAY_ENABLED=true` plus `SPRING_FLYWAY_ENABLED=false` gives disabled.

## 2. Which variable the release guard reads

`.github/workflows/dev-ecs-release.yml` (this worktree), lines 126-136, runs for every service except `gateway`. It reads the **active** task definition of the service and requires:
- exactly one `environment` entry named `SPRING_FLYWAY_ENABLED` with value `"false"` (line 131, and line 132 for the count of 1),
- no `secrets` entry named `SPRING_FLYWAY_ENABLED` (line 133).

It does **not** read `CARELOG_FLYWAY_ENABLED`. The deploy aborts with "Deploy blocked" (line 135) otherwise.

The guard runs on the revision the service currently uses: the job copies the live revision and replaces only the image (lines 137-160). A candidate revision therefore carries the variable only after the lead registers it through an authorized rollout.

## 3. Decision for the candidate Task

| Variable | Value | Where | Reason |
| --- | --- | --- | --- |
| `SPRING_FLYWAY_ENABLED` | `false` (plain env) | `candidates/carelog-tls/task-fragments.json` (`appContainerAddition.environment`), `carelog.tfvars.example` (`enrollment_tls_candidate.environment`) | Required by the guard. Added in this change. Never a secret. |
| `CARELOG_FLYWAY_ENABLED` | `false` | Already in the live runtime environment (`var.runtime.environment` from the protected inputs, not in the files I own) | Harmless and redundant with the above. Keep it so the live config does not change. |
| `SPRING_PROFILES_ACTIVE` | `prod` | Already in the live runtime environment | Keeps the production profile (and its CORS, secret import and Redis TLS settings). Must stay in the protected inputs. |

Behaviour change against live `:6`: none for Flyway. Live has `CARELOG_FLYWAY_ENABLED=false` and no `SPRING_FLYWAY_ENABLED` (checked on all six revisions, see §4), so Flyway was already disabled. The new variable only satisfies the guard.

## 4. DEV database V9 status

### Evidence collected

| Check | Result | Command or source |
| --- | --- | --- |
| Carelog ECS revisions 1-6 | All six: `CARELOG_FLYWAY_ENABLED=false`, no `SPRING_FLYWAY_ENABLED`, no Flyway secret. Image digest `sha256:7dd7b858…` (`:6`) on all six. Registered 2026-11-21 03:02Z to 03:17Z. | `aws ecs describe-task-definition` for `ranikun-carelog-dev-api:1` to `:6` (env names and values only). |
| CloudWatch `/ecs/ranikun-carelog-dev-api` | Retention 14 days. Created 2026-11-21 03:02Z. Earliest stream 03:10Z. 0 events for patterns `Flyway`, `flyway`, `schema history`, `Migrating`, `migrat`. | `aws logs describe-log-groups`, `aws logs filter-log-events` (all pages). |
| App start with `ddl-auto: validate` | Successful starts at 03:17, 03:19 and 03:21Z on 2026-11-21 (`Started CarelogApplication`). Earlier failures at 03:06-03:08Z were configuration (`gateway.internal-secret must be configured`), not schema. No schema-validation error line found. | `filter-log-events` on `Started CarelogApplication`, `Unable to start`, `Caused by`. |
| RDS `dev-shared` (Aurora PostgreSQL 16.15, cluster `dev-shared`, instance `dev-shared-1`) | Instance created 2026-11-20 08:19Z. Data API disabled. IAM DB auth disabled. No manual snapshots. Events in 14 days: topology, parameter adjustment, restart, create, and a system update. No migration-related event. | `aws rds describe-db-instances`, `describe-db-clusters`, `describe-events --duration 20160`, `describe-db-snapshots --snapshot-type manual`. |
| GitHub `carelog-be` runs | DEV releases 44706998265 (2026-11-20, `deploy_enabled` false) and 45136354872 (2026-11-23, deploy skipped). Their logs contain no migration or Flyway output. The `test` jobs use Testcontainers, not the DEV DB. | `gh run list`, `gh run view --log` (grep). |
| Repo rules | `carelog-be/.github/DEV_RELEASE.md` line 3: the release workflow "does not deploy PROD or run Terraform or migrations". `carelog-be/docs/operations/carelog-v1-container-foundation.md`, section "Database migration gate": Flyway stays disabled until a gate is complete. | `git show 5d6aa88c:…` |

### Interpretation

- No recorded run applied Flyway to DEV. The only Flyway-enabled config is in source (`application.yml`), and no deployed revision sets it on.
- The DEV database existed before the first Carelog app run (created 2026-11-20, first Carelog log 2026-11-21 03:10Z). Carelog started on 2026-11-21 with `ddl-auto: validate` and passed. So the tables required by the 318e1afe entity model existed by then, but no record shows how they were created. This is **unknown**, not a Flyway run.
- V9 (`users.external_account_id`, `external_manager_projection_receipts`, CHECK constraint) is not in any recorded automation. Nothing in CI, the release workflow, or the task definitions can apply it: the guard blocks Flyway and the app has no migration runner. The old app's successful validation does not prove V9 is absent, since Hibernate validation checks only the mapped columns of the old entities.

### Verdict

- V1-V8 in DEV: **unknown** (schema exists; the applying mechanism is not recorded; Flyway history not verified).
- V9 in DEV: **unknown**. No evidence of application; no mechanism that would have applied it. Treat as **not applied** for planning, and verify before any candidate deploy. A candidate built from 2630045e would fail `validate` at startup if the `external_account_id` column is missing, which the circuit breaker would catch. That is a plausible failure mode, not a test result.

### Access required for a definitive answer (not used)

- Network path: a host inside the DEV VPC with TCP 5432 to `dev-shared` (its security group allows only the existing app/Core sources). The known paths are the ECS tasks themselves; ECS Exec and one-off `run-task` are write actions and are out of scope.
- Credential owner: the DEV platform owner of the database. The app user's password is in Secrets Manager (ARN referenced by the task definition; not read). The request is for a **read-only** role with `SELECT` on the schema history and `information_schema`.
- Query (for whoever runs it, against the database that holds the Carelog schema, default `public` per `V1__baseline_current_schema.sql`):
  `SELECT version, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;`
  If the table is absent, the schema has never been managed by Flyway and that is the answer. Optional second check:
  `SELECT column_name FROM information_schema.columns WHERE table_name = 'users' AND column_name = 'external_account_id';`
- Also needed: confirmation whether `dev-shared` hosts other products' schemas (so that any V9 change affects others).

## 5. What was not done

- No Spring Boot process was run. The `CarelogApplicationTests` and `IdentityFoundationMigrationTest` need JDK 21, Gradle and Docker Testcontainers; no JDK is installed on this host.
- No SQL connection to the DEV database.
- No ECS, RDS, or Secrets Manager writes.

## 6. 2026-11-24 update: Core V3, Carelog V9 and shared database (read-only)

This section was added on 2026-11-24 for the B3 request. Sections 1-5 above stay as written.

### 6.1 Shared database

Both services connect to the same Aurora cluster endpoint (host part only, from the task definitions; credentials not read):
- Core `ranikun-platform-dev-core:3`, `PLATFORM_IDENTITY_DATASOURCE_URL`: host `dev-shared.cluster-c1i6wq6ka706.ap-northeast-2.rds.amazonaws.com`, database `app`. Core's own migrations use schema `identity` (`IdentityDatabaseSchema.NAME`, `IdentityDatabaseSchema.java`).
- Carelog `ranikun-carelog-dev-api:6`, `SPRING_DATASOURCE_URL`: same host, database `app`. Carelog's V1 is unqualified, so it uses schema `public`.

### 6.2 Core V3 (`V3__carelog_registration_operation.sql`)

Introduced by commit `dc635694…` (PR #71), so it is in the candidate `8353cec4` and not in live `ad9f8428` (live migration directory: `V1__identity_schema.sql`, `V2__refresh_session_single_account.sql`; verified at `39c5ccd4…`).

| Check | Evidence | Result |
| --- | --- | --- |
| Applied by a Core start in DEV | `/ecs/ranikun-platform-dev-core`, 2026-11-21 03:02:56-03:02:59Z: `Schema history table "identity"."flyway_schema_history" does not exist yet`, `Successfully validated 2 migrations`, `Migrating schema "identity" to version "1 - identity schema"`, `… version "2 - refresh session single account"`, `Successfully applied 2 migrations to schema "identity", now at version v2` | V1 and V2 applied by the app. **V3 not in this run** (it did not exist in the live image). |
| Later starts | 03:11:15-03:11:17Z: `Successfully validated 2 migrations`, `Current version of schema "identity": 2`, `Schema "identity" is up to date. No migration necessary.` | Last recorded Flyway state: **version 2**. |
| Any later Core start | Log stream `22ae6d8c…` runs 03:10-12:39Z on 2026-11-21 (no restart in that stream); no Flyway line after 03:11:17Z. `ranikun-platform-dev-core` service now ACTIVE, desired 0, running 0, task def `:3`. | No later Flyway run in the log group. |
| Startup failures | 02:59:30Z and 03:02:25Z (`Application run failed`): `Identity Auth requires the Product claims integration when no CRMIdentityProjectionPort is configured` (configuration, before the Flyway run) | Not a migration failure. |
| **Verdict** | **Not applied** as of the last recorded Core start (2026-11-21 03:11Z, version 2). No record of a manual application. | Unknown whether SQL was run by hand; none recorded. |

What would decide it: a read-only query against `identity.flyway_schema_history` and the schema objects (below).

### 6.3 Startup behaviour when the migration is missing

Core (`platform-core`, candidate `8353cec4`):
- Persistence is enabled by default: `IdentityPersistenceConfiguration.java:32-35` `@ConditionalOnProperty(... matchIfMissing = true)`.
- Flyway runs inside application startup: `IdentityPersistenceConfiguration.java:110-112` (`FlywayMigrationStrategy` calls `IdentityLegacySchemaGuard.migrate`), and `IdentityLegacySchemaGuard.java:31` calls `flyway.migrate()`. There is no flag to skip it. So starting the candidate **applies V3 to DEV automatically** on the first start (no approval gate in the repository).
- Hibernate runs with `hbm2ddl.auto=validate` (`IdentityPersistenceConfiguration.java:119-120`). If V3 were missing from the database, the new entity mapping (`credential_revision`, `carelog_registration_operation`) would fail schema validation at startup.
- If the migration itself failed (for example, the trigger or CHECK), startup fails before the app serves traffic.

Carelog (`carelog-be` `5d6aa88c`, image `2630045e`):
- Flyway is enabled in the base profile (`application.yml:17` `enabled: true`) but in production it is `enabled: ${CARELOG_FLYWAY_ENABLED:false}` (`application-prod.yml:21`). The DEV release guard forces `SPRING_FLYWAY_ENABLED=false` (`dev-ecs-release.yml` lines 131-133), so Flyway does **not** run at startup. V9 is never applied by the app.
- Schema validation: `ddl-auto: validate` (`application.yml:11`, `application-prod.yml:19`). If V9 (`users.external_account_id`, the receipts table, the CHECK) is missing, Hibernate fails at startup with a schema-validation error. No DDL is executed.
- Therefore the candidate Carelog cannot start in DEV until V9 has been applied by another route.

### 6.4 Carelog V9 status

Unchanged from sections 4 and 5: **unknown**. No new evidence was found. The Carelog log group (`/ecs/ranikun-carelog-dev-api`) still has zero Flyway lines. No Carelog revision enables Flyway.

### 6.5 Read-only queries and access needed

Core V3 (schema `identity`, database `app`):
```sql
SELECT version, description, success, installed_on FROM identity.flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;
SELECT column_name FROM information_schema.columns WHERE table_schema = 'identity' AND table_name = 'password_credentials' AND column_name = 'credential_revision';
SELECT to_regclass('identity.carelog_registration_operation') IS NOT NULL AS table_present;
```

Carelog V9 (schema `public`, database `app`):
```sql
SELECT version, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;
SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'external_account_id';
```

Needed for a definitive answer (not used here):
- Network path: a host inside the DEV VPC with TCP 5432 to `dev-shared` (the cluster is private; IAM database auth and the Data API are disabled per the RDS metadata). ECS Exec and one-off `run-task` are writes and are out of scope.
- Credential owner: the DEV database owner, for a **read-only** role with `USAGE` on schemas `identity` and `public`, `SELECT` on the two `flyway_schema_history` tables, and `information_schema` access. The application secrets (`PLATFORM_IDENTITY_*` and Carelog datasource) are not to be used or read.
- The Core and Carelog history tables must be read from the same database, `app`.
