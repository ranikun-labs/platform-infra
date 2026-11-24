# Evidence: Core rollback after Flyway V3 (isolated Docker proof)

Scope: isolated local proof only. No DEV or AWS resource was touched, no DEV database connection was made,
and no secret value was read. All passwords, keys and hashes are random or invented per run and exist only in
a temporary directory that the runner deletes on exit.

Runner: `candidates/core-rollback-test/run.sh` (README in the same directory).
Authoritative run: `run=crt179550297236394`, `RESULT: no FAIL (0 failures)`, `exit=0`, 2026-11-24 (UTC 06:50-06:55).
Earlier runs (7 to 9) exposed harness faults, listed in section 6. They are not results about Core.

## 0. Status of this evidence (read first)

- **Conditionally verified in an ISOLATED local environment only** (Docker, PostgreSQL 16.15, throwaway data, roles
  and grants created by the runner).
- **NOT verified on the real DEV database.** The live DEV configuration differs from the isolated roles (see 0.1).
- Nothing in this document shows the DEV state. For DEV status and the blocked read-only paths see
  `docs/handoff/evidence-flyway-v9.md` section 8.

Not verified on DEV (must be checked there before relying on the verdict):
- Aurora PostgreSQL specifics: TLS (`sslmode=require` in DEV, `disable` here), parameter groups, failover.
- DEV roles and grants: who owns schema `identity` and `public`, the actual grants on `flyway_schema_history`.
- `search_path` for the DEV roles (the test sets `search_path = identity` itself).
- Data volume and `ALTER TABLE ... ADD COLUMN ... DEFAULT 0` lock time on DEV tables.
- ALB and ECS health checks, secret injection, and the TLS proxy path.
- Registration retry against the real Carelog enrollment endpoint (SKIP in this run).

### 0.1 Finding: DEV does not use the role separation tested here

The live task definitions reference the same Secrets Manager secret for both roles (names only, values not read):
- Core `ranikun-platform-dev-core:3`: `PLATFORM_IDENTITY_DATASOURCE_USERNAME/PASSWORD` and
  `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_USERNAME/PASSWORD` all reference `ranikun/dev/shared-db-admin-DmopGX`.
- Carelog `ranikun-carelog-dev-api:6`: `SPRING_DATASOURCE_USERNAME/PASSWORD` reference the same secret.

So in DEV the runtime application and Flyway (if it runs) use the same admin identity, which owns or can
alter everything. The isolated test separated a migration owner from a DML-only runtime role. That separation is not
the live configuration. The conditions C1-C3 in section 1 are therefore conditions for a **future** role split,
not a description of DEV today. The DEV owner and grants are unknown (see `evidence-flyway-v9.md` section 8).

## 1. Answer

**Conditionally yes, in the isolated environment. The previous Core image can be used as a rollback target after
the new Core image has applied V3, with no Flyway or setting change, provided the migration and runtime roles are
separated as tested (C1-C3). DEV does not currently separate them (section 0.1), so this is not established for DEV.**

Conditions that the proof shows are required:

| # | Condition | Evidence |
| --- | --- | --- |
| C1 | Flyway (migration) datasource stays the migration role. Default `*:future` tolerance is kept (no ignore-pattern override). | 3.migrator PASS (previous Core starts on the V3 DB with defaults). 3.override-missing-only shows that overriding with `*:missing` alone blocks startup. |
| C2 | The runtime role keeps `SELECT` on `identity.flyway_schema_history` if Flyway ever runs with the runtime role. | 2c FAIL-by-design: new Core, runtime role, after V3, fails with `permission denied for table flyway_schema_history`. 3.runtime: the same failure for the previous Core. 2c2 with SELECT granted: starts. |
| C3 | Do not rely on Core re-applying V3 on rollback. The previous Core ignores V3 and does not re-run it. | 5.no-rerun: after the switch back to the new Core, V3 is not re-applied (same rank and checksum, one row). |

Rollback was exercised in both directions on the same database: new Core (V3 applied), previous Core (login,
refresh, password change work, Section 3), new Core again (login works, no re-apply). Data counts were unchanged.

## 2. Environment

| Item | Value |
| --- | --- |
| Previous Core | `124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001` (Flyway V1, V2) |
| New Core | `124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf` (adds V3) |
| PostgreSQL | `postgres:16-alpine`, server 16.15 (DEV is Aurora PostgreSQL 16.x; Aurora specifics not covered) |
| Redis | `redis:7-alpine`, no auth, no TLS |
| JDK for helpers | `eclipse-temurin:21-jdk` (BCrypt hashes, claims stub) |
| Roles | `identity_owner` (migration; owns schema `identity`), `identity_runtime` (no DDL), database `app` |
| Network | private Docker network, no published ports, `sslmode=disable` inside it |
| Host | Windows 11, Docker Desktop, Git Bash |

## 3. Results per step (run10)

Legend: PASS/FAIL = the runner's check. "expected" = the step checks a known failure and passes when it occurs.

| Step | Result | What was checked | Log excerpt (no secrets) |
| --- | --- | --- | --- |
| preflight:image | PASS | both digests present locally | `image present: sha256:ad9f8428...` / `sha256:8353cec4...` |
| preflight:roles | PASS | owner and runtime roles created | identity_owner (migration) and identity_runtime (no DDL) |
| preflight:postgres | PASS | server version | `PostgreSQL server_version 16.15` |
| preflight:bcrypt | PASS | throwaway hashes generated | eclipse-temurin:21-jdk |
| 1 | PASS | previous Core on empty DB applies V1, V2 | `Successfully applied 2 migrations ... now at version v2`; history 1:true 2:true |
| 2a | PASS (expected) | new Core, runtime role only, before V3 is applied: must not start, V3 rows = 0 | `Unable to start embedded Tomcat` (wrapper; V3 not present) |
| 2a2 | PASS | history SELECT granted, V3 pending: fails on DDL, not on the history read | `ERROR: must be owner of table password_credentials` |
| 2b | PASS | new Core with migration role applies V3 | `Successfully applied 1 migration ... now at version v3`; history `3 v3 carelog registration operation success=true` |
| 2c | PASS (expected) | runtime role only, after V3, no SELECT: must fail on the history read | `permission denied for table flyway_schema_history` |
| 2c2 | PASS | runtime role with history SELECT, nothing pending: starts | starts |
| 4a.login | PASS | new Core login on V3 DB | HTTP 200, tokens issued |
| 4a.refresh | PASS | new Core refresh | HTTP 200, new refresh token |
| 4a.password | PASS | password change through the DB (`UPDATE password_credentials`) | `credential_revision 0->1 (trigger)`, old password HTTP 401, new HTTP 200 |
| 3.migrator | PASS | previous Core starts on V3 DB, default Flyway settings | `Successfully validated 3 migrations`; `Current version of schema "identity": 3` |
| 4b.login | PASS | previous Core login on V3 DB | HTTP 200 |
| 4b.refresh | PASS | previous Core refresh | HTTP 200 |
| 4b.password | PASS | previous Core password change, trigger still active | revision 2, new password HTTP 200, old HTTP 401 |
| 3.ignore-future | PASS | previous Core with `SPRING_FLYWAY_IGNORE_MIGRATION_PATTERNS=*:future` starts | starts |
| 3.override-missing-only | PASS (expected) | `*:missing` alone (overrides the default) must block startup | `Detected applied migration not resolved locally: 3.` |
| 3.runtime | PASS (expected) | previous Core, runtime role only, after V3: must fail on the history read | `permission denied for table flyway_schema_history` |
| 5.no-rerun | PASS | new Core restarted after the rollback cycle | V3 not re-applied: 1 row, same rank and checksum; counts (1,1,1) unchanged |
| 5.login | PASS | new Core login after the cycle | HTTP 200 |
| 5.registration-retry | SKIP | not run | Carelog enrollment client accepts only https or loopback; no endpoint in the isolated network |

Result: 0 FAIL, 1 SKIP. Containers, networks and temp files were removed (checked afterwards: no `core-rollback-test`
labelled objects and no `crt-` containers remained).

## 4. Migration role vs runtime role

- The **migration role** (owner of schema `identity`) can run V3. Without ownership, V3 fails at
  `ALTER TABLE password_credentials` (2a2 shows `must be owner of table password_credentials`).
- The **runtime role** cannot read `identity.flyway_schema_history`. Flyway's validate step reads that table on
  every start. Without the SELECT grant, both images fail at startup with the same message (2c, 3.runtime). This
  is a startup dependency, not an application query failure.
- With SELECT granted and nothing pending, the runtime role starts both images (2c2 for the new Core; the previous
  Core's runtime-only start with SELECT was not run separately, so this is inferred from the same code path).
- The DDL needed by V3 is never needed by the runtime role. The runtime role only needs DML on the identity tables,
  which the Core runtime privilege reconcile grants.
- Code reading (not re-verified in this run): `IdentityRuntimeSchemaPrivileges.reconcile` REVOKEs ALL on
  `flyway_schema_history` from the runtime role on every migrate call. That is consistent with C1 (Flyway runs as the
  owner). It means a runtime-only Flyway configuration would not work for either image, before or after V3.

## 5. What this does NOT prove

- Aurora PostgreSQL specifics (storage, failover, parameter groups, IAM auth, SSL). Local test used no TLS.
- DEV data volume, lock behaviour of `ALTER TABLE ... ADD COLUMN ... DEFAULT 0` on a large table, or migration time.
- DEV role grants and `search_path`. The test sets `search_path = identity` for the roles; DEV was not inspected.
- Real Carelog flows: registration retry (5.registration-retry) was SKIP. The product-claims call is a stub that
  always returns an eligible MANAGER claim, so authorization logic against the real Carelog service is not covered.
- Network paths, ALB/ECS health checks, secrets injection, and TLS.
- Whether DEV is currently on V3 (see Section 7).

## 6. Harness faults found and fixed (not Core behaviour)

- Git Bash `/tmp` paths: fixed with `cygpath -m`.
- PostgreSQL readiness during initdb: now requires two successful `select 1`.
- Login returned "HTTP none" with busybox `wget -S`: switched to curl in the JDK image with an explicit code line.
- Login returned 503 because the product-claims base URL was unreachable: a `ClaimsStub` container now answers.
- Management port UP before the API served requests (503): readiness now also requires a non-503 API response.
- Earlier 2c and 3.runtime expectations were reported as FAIL although the failure was the expected one: now they
  pass only when the root cause is `flyway_schema_history`.
- Editing `run.sh` while a run was active caused syntax errors (runs 3 and 7). Rule followed: no edits during a run.

## 7. DEV items

- The DEV V3 and V9 status is recorded in `docs/handoff/evidence-flyway-v9.md` (section 7). This isolated test
  produced no new DEV evidence.
- To verify on DEV (read-only, through the approved path): that the migration history has V3 or not, that
  `identity_runtime` has no SELECT or DDL on `flyway_schema_history`, and that the DEV `search_path` for both roles
  is `identity` (or whatever the live configuration uses).

## 8. Reproduce

```bash
bash candidates/core-rollback-test/run.sh
# or with other digests:
CORE_PREVIOUS_IMAGE=<ref> CORE_NEW_IMAGE=<ref> bash candidates/core-rollback-test/run.sh
```

Exit 0 means no FAIL. Exit 1 means at least one FAIL. Exit 2 means a script error.
