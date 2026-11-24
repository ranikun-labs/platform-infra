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

## 7. 2026-11-24 B4: isolated rollback test (no new DEV evidence)

The isolated Docker proof of the Core V3 rollback (`candidates/core-rollback-test/`, results in `evidence-core-rollback-test.md`) used only local PostgreSQL. It does not read or change DEV. No new DEV evidence was found: the DEV V3 and V9 status above is unchanged (V3 not applied as of the last recorded Core start, 2026-11-21 03:11Z; V9 unknown).

## 8. 2026-11-24 B5: DEV status table and blocked read-only paths

Scope: existing read-only paths only (AWS describe, list and filter with profile `ranikun-admin`, ap-northeast-2; repo search).
No secret value was read (`describe-secret` and task-definition names only), no DB connection, no ECS task or Exec, no write.
Repo HEAD: a142bc3b.

### 8.1 DEV status (known vs unknown)

| Item | Status | Evidence (date) | Source |
| --- | --- | --- | --- |
| Core V1, V2 in DEV | Known: applied | 2026-11-21 03:02:56-03:02:59Z "Successfully applied 2 migrations ... now at version v2"; 03:11:17Z "Current version ... 2" | `/ecs/ranikun-platform-dev-core` |
| Core V3 in DEV | **Unknown. Last recorded state: not applied** (version 2 at 03:11Z) | No Flyway line after 2026-11-21 03:11:17Z in the 7-day retention window | same log group, `filter-log-events` |
| Core schema additions (`password_credentials.credential_revision`, `carelog_registration_operation`) | **Unknown** (V3 not recorded as applied) | none | needs the queries in 8.3 |
| Carelog V9 in DEV (`users.external_account_id`, receipts table, CHECK) | **Unknown.** No evidence of application. Flyway is disabled for Carelog (`CARELOG_FLYWAY_ENABLED=false`, no `SPRING_FLYWAY_ENABLED`) in the task definitions | `ranikun-carelog-dev-api:1-6` (section 4) | ECS describe |
| Carelog Flyway lines in logs | None in the 14-day retention window. 2026-11-21 03:08-03:15Z show `Unable to start web server` and `Application run failed`; the root cause is not in the filtered lines | `/ecs/ranikun-carelog-dev-api` `filter-log-events` for Flyway, "permission denied", "must be owner" | CloudWatch |
| Core runtime and Flyway DB users | **Known: same secret.** `ranikun-platform-dev-core:3`: `PLATFORM_IDENTITY_DATASOURCE_USERNAME/PASSWORD` and `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_USERNAME/PASSWORD` all reference `ranikun/dev/shared-db-admin-DmopGX` (keys `username`, `password`) | ECS describe (names only) | ECS |
| Carelog runtime DB user | **Known: same secret.** `ranikun-carelog-dev-api:6`: `SPRING_DATASOURCE_USERNAME/PASSWORD` reference `ranikun/dev/shared-db-admin-DmopGX` | ECS describe (names only) | ECS |
| Owner, DDL rights, SELECT on history, search_path (schemas `identity`, `public`) | **Unknown** | no DB read possible (8.2) | - |
| Secret `ranikun/dev/shared-db-admin` | Metadata only: last changed 2026-11-21 03:24 JST, no description, rotation not enabled | `secretsmanager describe-secret` | Secrets Manager |
| Cluster `dev-shared` | Aurora PostgreSQL 16.15, available, port 5432, IAM DB auth **disabled**, Data API **disabled**, parameter group `default.aurora-postgresql16`, no log exports | `rds describe-db-clusters` (2026-11-24) | RDS |
| Instance `dev-shared-1` | `db.serverless`, not publicly accessible, Performance Insights **off**; `describe-db-log-files` returned "not ready" | `rds describe-db-instances` | RDS |
| Recent DB events | Cluster created 2026-11-20 08:14Z; repeated pause and resume of `dev-shared-1` on 2026-11-20 | `rds describe-events` | RDS |
| Core and Carelog services | Both `desiredCount 0`, `runningCount 0` in cluster `dev-shared` (last steady-state events 2026-11-24 15:41 JST). No live task is using the DB now | `ecs describe-services` | ECS |

### 8.2 Blocked paths (each tried; none opened a new network path or read a secret)

| Path | Result | Access still needed |
| --- | --- | --- |
| AWS CLI, profile `ranikun-admin` | Works when passed as `--profile`; identity is the SSO role `AWSReservedSSO_RanikunDevAdmin_*` | none for metadata |
| Other profiles (`ranikun-dev`, `ranikun-dev-shared-apply`, ...) | Not used. `rankun-admin-isolated` SSO token is expired; re-login is an interactive step, not done | not needed for this scope |
| CloudWatch Logs (Core, Carelog) | Done (8.1). Retention: Core 7 days, Carelog 14 days, so older Flyway lines are gone | none |
| ECS services and task definitions (describe only) | Done (8.1). No task started, no Exec | none |
| RDS metadata and events | Done. Parameter-level `search_path` not read | optional: `rds describe-db-cluster-parameters` filtered to `search_path` (read-only) |
| RDS log files | Blocked: `dev-shared-1` "not ready" at the time of the call | retry once the instance is `available` |
| Performance Insights | Not enabled on `dev-shared-1` | none for this scope |
| RDS Data API, IAM DB auth | Both disabled on `dev-shared` (read from the cluster) | none (do not enable) |
| SQL connection to DEV (TCP 5432) | **Blocked by the rules of this task.** The only credential is `shared-db-admin`, which may not be used. No read-only DB role exists. The cluster is private (VPC `vpc-0450d6431bc98c338`, SG `sg-0004121ff1c8f81dc`) | a host inside the DEV VPC with TCP 5432 to `dev-shared-1`, and a read-only DB role (8.3) whose credential the DB owner supplies through an approved route |
| Repo inspection routes | None found for DEV. Matches for `psql`, `bastion` and `ssm start-session` are local docker-compose e2e scripts and handoff docs. No read-only DEV query runbook exists | none |
| SSM Parameter Store, Secrets Manager values | Not read (metadata only) | none needed |

### 8.3 Access and SQL needed for a definitive answer (read-only, run by the DB owner)

Access (proposed, least privilege):
- Network: a host in VPC `vpc-0450d6431bc98c338` with TCP 5432 to `dev-shared-1`, reachable from that host only.
- Database role `ro_flyway_check` (LOGIN), with:
  `GRANT CONNECT ON DATABASE app TO ro_flyway_check;`
  `GRANT USAGE ON SCHEMA identity, public TO ro_flyway_check;`
  `GRANT SELECT ON identity.flyway_schema_history, public.flyway_schema_history TO ro_flyway_check;`
  Optional, only if the owner wants the DEV search_path reproduced: `ALTER ROLE ro_flyway_check SET search_path = identity, public;`
  No table data grants, no DDL, no `pg_read_all_data`.
- Credential: owned by the DEV DB owner and delivered outside this task. The application secrets are not used.

Queries (database `app`, run by the read-only role; the owner may run the grant query as owner):

```sql
SELECT installed_rank, version, description, success, installed_on FROM identity.flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;
SELECT installed_rank, version, description, success, installed_on FROM public.flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;
SELECT nspname, pg_get_userbyid(nspowner) AS owner FROM pg_namespace WHERE nspname IN ('identity', 'public');
SELECT schemaname, tablename, tableowner FROM pg_tables WHERE schemaname IN ('identity', 'public');
SELECT grantee, table_schema, table_name, privilege_type FROM information_schema.table_privileges WHERE table_name = 'flyway_schema_history';
SELECT rolname, rolsuper, rolcreatedb, rolinherit, rolcanlogin FROM pg_roles WHERE rolname IN ('<shared-db-admin username, from the owner>', 'ro_flyway_check');
SELECT rolname, rolconfig FROM pg_roles WHERE rolconfig IS NOT NULL;
SELECT to_regclass('identity.carelog_registration_operation') IS NOT NULL AS core_v3_table;
SELECT column_name FROM information_schema.columns WHERE table_schema = 'identity' AND table_name = 'password_credentials' AND column_name = 'credential_revision';
SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'external_account_id';
```

Notes: `information_schema.table_privileges` shows only the grants the querying role can see, so run it as the owner to
see all grantees. The admin role name is read by the owner from the secret; it is not written here. The SQL was parsed
and run on a throwaway PostgreSQL 16 container with no DEV data; the container was removed.

### 8.4 Open questions for the DEV owner

1. Is Core V3 applied in DEV? (`identity.flyway_schema_history` rows and the column and table checks.)
2. Is Carelog V9 applied in DEV? (`public.flyway_schema_history` and `users.external_account_id`.)
3. Who owns schemas `identity` and `public`, and does `shared-db-admin` hold DDL on them? (Expected: yes, it is the admin identity both services use.)
4. Is `search_path` set for the DEV roles? Is `identity` reached through search_path or by qualified names?
5. Should the runtime application and Flyway use separate roles in DEV before any V3 or V9 apply? (Not decided here.)
