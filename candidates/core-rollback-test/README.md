# Core rollback proof (isolated)

Question: after the **new** Core image has applied Flyway V3 to a database, can the **previous** Core image
still be used as a rollback target on that database?

The runner starts a throwaway PostgreSQL, Redis and the two Core images on a private Docker network,
then runs the steps in `run.sh`. It never connects to DEV, never reads a secret, and writes no AWS resource.

## Files

| File | Purpose |
| --- | --- |
| `run.sh` | Runner. Prints `[PASS]`/`[FAIL]`/`[SKIP]` per step; exit 0 only when no step fails. |
| `sql/init.sql` | Roles `identity_owner` (migration, owns schema `identity`) and `identity_runtime` (no DDL), database `app`. |
| `java/BcryptGen.java` | Prints a BCrypt hash for a throwaway password (uses the Core jar's `spring-security-crypto`). |
| `java/ClaimsStub.java` | Test stub for the product-claims endpoint Core calls during login and refresh. No credential check. |
| `.gitattributes`, `.gitignore` | LF line endings; ignores leftover temp directories. |

## Prerequisites

- Docker (Linux engine or Docker Desktop). Git Bash on Windows is fine; `run.sh` converts paths with `cygpath -m`.
- Bash 4+, `od`, `sed`, `grep`, `mktemp`.
- Images (digest-pinned; the runner uses them by digest):
  - previous Core `ranikun/platform/core@sha256:ad9f8428…` (Flyway V1, V2 only),
  - new Core `ranikun/platform/core@sha256:8353cec4…` (adds V3),
  - `postgres:16-alpine` (same major as Aurora PostgreSQL 16.x in DEV), `redis:7-alpine`,
    `eclipse-temurin:21-jdk`, `busybox:latest`.
- If a Core image is missing locally, the runner pulls it from ECR read-only with a temporary `DOCKER_CONFIG`
  (removed on exit). That needs `aws` on PATH and `AWS_PROFILE` with ECR read permission. No other AWS call is made.

## Run

```bash
bash candidates/core-rollback-test/run.sh
# Override images (by digest, never by tag):
CORE_PREVIOUS_IMAGE=<ref> CORE_NEW_IMAGE=<ref> bash candidates/core-rollback-test/run.sh
```

Runtime: roughly 10 to 20 minutes (each Core start takes about 1 to 2 minutes locally).

Expected result on the two images in the evidence doc: `RESULT: no FAIL`, `exit=0`. Step `5.registration-retry`
is always `SKIP`. The runner exits 1 if any step prints FAIL, and 2 on a script error.

## Expected-failure steps

Some steps check that a start *fails* in a known way and print PASS when it does: `2a` (new Core, runtime role,
before V3), `2c` and `3.runtime` (runtime role without SELECT on `flyway_schema_history`), `3.override-missing-only`
(`*:missing` alone blocks startup). Those steps look for a specific root cause, not just a non-zero exit.

## What it generates

All credentials are random per run: DB role passwords, the JWT signing key, the product-claims service secret,
and BCrypt hashes for three throwaway passwords. They live only in a `mktemp` directory (mode 700, env files
mode 600). On exit the runner removes every container, the network, the temp Docker config and the temp
directory. Containers are labelled `core-rollback-test=<run id>` so a leftover can be removed with
`docker rm -f $(docker ps -aq --filter label=core-rollback-test)`.

## Stubs and settings used

| Dependency | How it is satisfied | Why |
| --- | --- | --- |
| PostgreSQL | `postgres:16-alpine`, no TLS (`sslmode=disable`) | Same major as DEV. DEV uses `sslmode=require` and Aurora; not covered. |
| Redis | `redis:7-alpine`, no password, no TLS | Core requires a Redis host (`IdentityRuntimeProperties.redisHost` is `@NotBlank`). |
| Product claims | `ClaimsStub` container on the private network, base URL `http://<stub>:8080` | Login, refresh and token rotation call `GET /api/v1/internal/identity/claims/{accountId}` and return 503 when it is unreachable (observed in an earlier run). The stub returns a fixed MANAGER claim. |
| Carelog enrollment / registration | not configured | Needs https or loopback and a Carelog endpoint. Step 5 registration retry is `SKIP`. |
| Kakao / OpenAI / SharedAI / audit | unset (defaults) | Not needed for the identity paths tested. |

Flyway: the migration role is configured as `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_*` (as the live DEV task does);
the runtime role is `PLATFORM_IDENTITY_DATASOURCE_*`. The "runtime-only" variant omits the Flyway datasource,
so Flyway uses the runtime role.

## Limits

See `docs/handoff/evidence-core-rollback-test.md` for results and what this does not prove (Aurora, data volume,
network paths, real Carelog flows, the DEV role search_path).
