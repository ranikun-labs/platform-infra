# Carelog TLS rollout and rollback (single-bundle design, draft, not executed)

Status: **no command in this document has been run.** Every command is a template. `<PLACEHOLDER>` values are filled only after owner approval. Secret values, tfvars, state, plan text and environment values never go into chat or Git.

Scope: the DEV service `ranikun-carelog-dev-api` (cluster `dev-shared`, account 124495093425, ap-northeast-2). Core and Gateway are out of scope except section 8.

## 0. Design this procedure assumes

- Proxy sidecar `carelog-tls-proxy` on 8080 (existing API allowlist) and 8443 (Core enrollment only).
- One Secrets Manager secret holds the server bundle as JSON (`tls_certificate`, `tls_private_key`). The sidecar reads it as **one** env var, `TLS_BUNDLE_JSON`, from a **bare ARN with no json-key and no version suffix**. There is no separate CA secret. The CA is baked into the Core trust-init image (see `docs/handoff/prep-cert-secrets.md`).
- The bundle secret is created and rotated by the owner, as described in `docs/handoff/prep-cert-secrets.md` section 3 (PutSecretValue and version rules); the recovery procedure is `prep-cert-secrets.md` section 11 (11.2 restores the previous version). This document does not repeat those commands.
- The enrollment bearer secret is **`<ENROLLMENT_SECRET_ARN>`** (`ranikun/dev/carelog/enrollment-service`). It is an existing secret and is referenced unchanged (see section 1).

Identifiers (not secret):
- Rollback target: `arn:aws:ecs:ap-northeast-2:124495093425:task-definition/ranikun-carelog-dev-api:6` (live revision; no TLS sidecar, no enrollment reference; image digest `sha256:7dd7b858abb0fe701d2ac3a5c6cd25bfedea7efdc1a7f47fdc28362961561e54`).
- Candidate image for the app: `sha256:2630045e50b01879b0d3462fcd38509b9255131af52928e3a04878c6ade11d39` (enrollment controller exists only in this build; it needs Flyway V9 in the database, see section 2).
- Observed app start: 161-179 s (three starts, 2026-11-21 DEV logs). Proxy health `startPeriod` 300 s.

## 0.1 The enrollment secret is protected

The following rules hold for every step in this document, including rollback:
- **No step puts, deletes, rotates, restores, or changes the version stages of `<ENROLLMENT_SECRET_ARN>`.** No `secretsmanager` write action targets it.
- The candidate task definition references it unchanged, as `CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET` = the exact ARN in the protected input `enrollment_secret_arn`. The ARN is copied verbatim, never re-typed or reformatted.
- Rolling back a task definition, or the bundle, never touches this secret. Rolling the service back to `:6` only removes the app container's reference to it (`:6` does not contain it). The secret itself stays as it is.
- Do not read its value (`get-secret-value`) to "verify" it. Verify only the reference string in the task definition.

## 1. Preconditions (stop if any fails)

1. Identity: `aws sts get-caller-identity` returns account 124495093425 and the approved DEV role. The caller is the only operator on this service.
2. Service state: `describe-services` shows ACTIVE, `desiredCount` 0, `runningCount` 0, PRIMARY deployment COMPLETED on `:6`.
3. Bundle: the owner confirms the bundle secret exists, has `AWSCURRENT` set to a bundle that contains both keys, and that the pair matched when it was written (prep-cert-secrets section 3.1). Do not read the value.
4. Proxy image: pushed to private ECR by digest. Recorded: repository, digest, and the approval for it. No placeholder or `SYNTHETIC` strings remain in the candidate file (`grep -c 'PLACEHOLDER\|SYNTHETIC'` = 0).
5. Database precondition for the candidate app image: Flyway V9 is applied in DEV (`users.external_account_id` exists). Current status is **unknown**; see `docs/handoff/evidence-flyway-v9.md`. Verify with a read-only check owned by the DB owner. Without V9, the candidate app fails `ddl-auto: validate` at start.
6. Flyway guard: the candidate app container carries `SPRING_FLYWAY_ENABLED=false` as a plain env (`task-fragments.json`, `carelog.tfvars.example`). Without it `dev-ecs-release.yml` (lines 131-133) blocks later image releases.
7. IAM: the execution role boundary and policy allow the proxy ECR repository, `TLS_BUNDLE_JSON` (bundle ARN) and the enrollment secret for **execution** (ECS pulls secrets as the execution role). Terraform must produce this before registration (section 3).
 8. Core V3 gate: section 8.1 is complete (read-only V3 status recorded, approval reference recorded, runtime-versus-migration decision recorded) before ANY start of Core on 8353cec4, and Core desired count is 0 until then.

## 2. Build the candidate task definition from `:6`

Start from the live revision, not from the Terraform baseline (`:1`). Save the working files in a private directory.

```bash
export AWS_PROFILE=<APPROVED_DEV_PROFILE> AWS_REGION=ap-northeast-2
CLUSTER=dev-shared; SERVICE=ranikun-carelog-dev-api; FAMILY=ranikun-carelog-dev-api
PROXY_IMAGE="<ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/<PROXY_REPO>@sha256:<PROXY_DIGEST>"
APP_IMAGE="<ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/<APP_REPO>@sha256:<APP_DIGEST>"   # 2630045e… if approved
BUNDLE_ARN="<SERVER_BUNDLE_SECRET_ARN>"          # bare ARN, no :key:: and no version suffix
ENROLL_ARN="<ENROLLMENT_SECRET_ARN>"             # copied verbatim from the protected input enrollment_secret_arn

aws ecs describe-task-definition --task-definition "$FAMILY:6" --output json > <PRIVATE_DIR>/td6.json
```

Merge with `jq` (the healthCheck object is copied from `candidates/carelog-tls/task-fragments.json`, not retyped):

```bash
jq --arg img "$PROXY_IMAGE" --arg app "$APP_IMAGE" --arg bundle "$BUNDLE_ARN" --arg enroll "$ENROLL_ARN" \
   --argjson hc '<HEALTHCHECK_OBJECT_FROM_task-fragments.json>' '
  .taskDefinition
  | {family,taskRoleArn,executionRoleArn,networkMode,containerDefinitions,volumes,
     placementConstraints,requiresCompatibilities,cpu,memory,pidMode,ipcMode,
     proxyConfiguration,inferenceAccelerators,ephemeralStorage,runtimePlatform}
  | with_entries(select(.value != null))
  | .volumes += [{"name":"carelog-tls"}]
  | .containerDefinitions |= (
      map(if .name == "ranikun-carelog-dev-api" then
              .image = $app
              | .portMappings = []
              | .environment = ((.environment | map(select(.name != "SERVER_ADDRESS" and .name != "CARELOG_IDENTITY_ENROLLMENT_ENABLED" and .name != "SPRING_FLYWAY_ENABLED")))
                  + [{"name":"SERVER_ADDRESS","value":"127.0.0.1"},
                     {"name":"CARELOG_IDENTITY_ENROLLMENT_ENABLED","value":"true"},
                     {"name":"SPRING_FLYWAY_ENABLED","value":"false"}])
              | .secrets = ((.secrets | map(select(.name != "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET")))
                  + [{"name":"CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET","valueFrom":$enroll}])
            else . end)
      + [{
          "name":"carelog-tls-proxy","image":$img,"essential":true,
          "portMappings":[{"containerPort":8080,"protocol":"tcp"},{"containerPort":8443,"protocol":"tcp"}],
          "mountPoints":[{"sourceVolume":"carelog-tls","containerPath":"/run/carelog-tls","readOnly":false}],
          "secrets":[{"name":"TLS_BUNDLE_JSON","valueFrom":$bundle}],
          "logConfiguration":{"logDriver":"awslogs","options":{
            "awslogs-group":"/ecs/ranikun-carelog-dev-api","awslogs-region":"ap-northeast-2","awslogs-stream-prefix":"tls-proxy"}},
          "healthCheck":$hc
        }])
' <PRIVATE_DIR>/td6.json > <PRIVATE_DIR>/carelog-td-candidate.json
```

Checks before registering (no secret values are printed):
```bash
F=<PRIVATE_DIR>/carelog-td-candidate.json
grep -c 'PLACEHOLDER\|SYNTHETIC' "$F"                                  # must be 0
jq '[.containerDefinitions[] | {n:.name, img:.image, ports:[.portMappings[]?.containerPort], secrets:[.secrets[]?.name]}]' "$F"
# expect: app ports [] and secrets = the :6 names + CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET; proxy secrets = [TLS_BUNDLE_JSON]
jq '[.containerDefinitions[] | select(.name=="ranikun-carelog-dev-api") | .environment[].name] | sort' "$F"   # SPRING_FLYWAY_ENABLED present once
```

## 3. Terraform for IAM and security group (approved plan only)

The candidate task definition needs the execution role to read the bundle and enrollment secret, and the Core security group needs access to 8443. These come from `environments/dev/carelog` with the protected inputs, after review:

```bash
cd environments/dev/carelog
terraform init -input=false -backend-config='bucket=<STATE_BUCKET>' -backend-config='region=ap-northeast-2' -backend-config='allowed_account_ids=["124495093425"]'
terraform plan -input=false -lock-timeout=5m -var-file='<PROTECTED_TLS_TFVARS>' -out='<SECURE_PLAN_PATH>'
# Review the resource addresses and actions only. Expected: one 8443 ingress rule added, the execution inline
# policy updated (bundle + enrollment ARNs), the baseline task definition replaced. Stop on any other change.
terraform apply '<SECURE_PLAN_PATH>'
```

The baseline task definition revision created here is not what the service runs. The service keeps its current revision until section 4.

## 4. Register and roll out (one service update)

```bash
aws ecs register-task-definition --cli-input-json "file://<PRIVATE_DIR>/carelog-td-candidate.json" \
  --query 'taskDefinition.{arn:taskDefinitionArn,rev:revision}' --output json
# Record CANDIDATE_TD_ARN from the output. Do not assume the revision number.

aws ecs update-service --cluster dev-shared --service ranikun-carelog-dev-api \
  --task-definition "<CANDIDATE_TD_ARN>" --desired-count 1
aws ecs wait services-stable --cluster dev-shared --services ranikun-carelog-dev-api
```

`--task-definition` and `--desired-count` in one call start a new deployment from `desired 0`. Circuit breaker rollback is enabled on the service, but it has not been tested for this change, so section 5 is the manual fallback.

## 5. Verification (all must pass before the change counts as live)

1. Service: `describe-services` shows one PRIMARY deployment COMPLETED on `<CANDIDATE_TD_ARN>`, `runningCount` 1, `pendingCount` 0.
2. Health: both containers report HEALTHY (`describe-tasks` for the running task, `healthStatus`). Proxy `startPeriod` is 300 s, so failures in the first five minutes do not count.
3. Logs (`aws logs tail /ecs/ranikun-carelog-dev-api --since 15m`): `Started CarelogApplication`; no `Schema-validation` error; the proxy `nginx -t` succeeded. No secret values in logs.
4. 8080 existing API: through the Gateway, customer and relation calls succeed with a real session (not the stub). `POST /api/v1/internal/v1/identity/carelog/enrollments/...` on 8080 returns 403.
5. 8443 enrollment: from Core (or the approved test path), a PUT to the enrollment path with a valid bearer returns the expected status; an invalid bearer returns 403; the certificate chain validates against the Core trust store.
6. Core claims path: `GET /api/v1/internal/identity/claims/{accountId}` on 8080 with Core credentials returns the expected result.

## 6. Rollback and recovery (fixed order)

Stop conditions are listed in section 7. Each step is one write; check the state before the next step.

### 6.0 Old certificate recovery (try first, bundle only)

Use this when the problem is the served certificate or the bundle version, and the task definition is correct.

1. Restore the previous Secret **version** of the single bundle `<BUNDLE_ARN>`: follow `docs/handoff/prep-cert-secrets.md` section 11.2 (move `AWSCURRENT` back to the previous version; the commands live there and are not repeated here). Only the bundle is changed. Nothing else in Secrets Manager is touched, and the enrollment bearer secret is never part of this step.
2. Force a new deployment of `ranikun-carelog-dev-api` on the current revision, so that new tasks read the restored version: `aws ecs update-service --cluster dev-shared --service ranikun-carelog-dev-api --task-definition <CURRENT_TD_ARN> --force-new-deployment`, then `services-stable`.
3. Verify the served certificate against the restored version's expected value. The expected value is the SHA-256 fingerprint of the restored leaf certificate, recorded at section 11.1 step 1 from the public certificate file (never a key). Compare only the fingerprint strings, from an approved Core task or test host:
   `openssl s_client -connect <TASK_IP>:8443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256`
   The output must equal the recorded value. Do not print the bundle, the private key or the full PEM. The container health check also compares the served fingerprint with the file on disk (`task-fragments.json`).
4. If the proxy still fails after steps 1-3 (UNHEALTHY after `startPeriod` plus retries, fingerprint mismatch, or 8443 not listening), go to section 6.1 below and roll the task definition back to `:6`.

### 6.1 Full rollback: task definition to `:6`

1. **Stop traffic and return to `:6`** (the fallback in section 6.0 step 4, or when the candidate must be removed).
   ```bash
   aws ecs update-service --cluster dev-shared --service ranikun-carelog-dev-api \
     --task-definition arn:aws:ecs:ap-northeast-2:124495093425:task-definition/ranikun-carelog-dev-api:6 --desired-count 0
   aws ecs wait services-stable --cluster dev-shared --services ranikun-carelog-dev-api
   ```
   Then `describe-services`: `taskDefinition` `:6`, `desiredCount` 0, `runningCount` 0.
2. **Record** the rollback target `:6`, the candidate revision, the time, and the reason, in the operations log.
3. **Bundle.** The `:6` revision does not reference the bundle, so reverting the bundle is not needed for the `:6` rollback. Recover the bundle only through section 6.0 (`prep-cert-secrets.md` section 11.2), and only before a new candidate is started again. Do not touch any other secret.
4. **Core ingress.** Remove the 8443 ingress rule by Terraform: set `enrollment_core_security_group_id = null` in the protected inputs, plan, review, apply. Do not delete it by hand, or state drifts.
5. **Execution policy.** Terraform reverts the execution inline policy to the baseline inputs (plan must show only the policy revert).
6. **Keep `:6` and the candidate revision** registered. Do not deregister `:6`. Deregistering the candidate needs release-owner approval and a retention period.
7. **Clean up later**: the proxy image, bundle versions and enrollment reference are removed only after no task definition references them and the retention period has passed. The enrollment secret itself is never part of cleanup.

Database: migrations (V9 if applied) are not reversed by this procedure. Rolling back the image does not undo DDL. Any DB change needs its own approved plan.

## 7. Stop conditions

Stop and escalate before the next step if any of these holds:
- The account, role or cluster is not the approved DEV target.
- Service is not ACTIVE with `desiredCount` 0 before rollout, or the deployment is not COMPLETED.
- Another operator or pipeline is changing the same service.
- The candidate file contains `PLACEHOLDER` or `SYNTHETIC`, or the proxy digest is not the approved one.
- V9 is not verified as applied (for the 2630045e app image) or the status is unknown.
- `SPRING_FLYWAY_ENABLED=false` is missing from the app container, or any Flyway setting is enabled.
- The plan shows any change to the enrollment secret resource, its version stages, or its policy beyond the reviewed read permission.
- A candidate task definition has the enrollment ARN altered or re-typed, or any secret value appears in logs or plan output.
- Health stays UNHEALTHY after `startPeriod` plus three retries (about 10 minutes): roll back (section 6).
- The rollback itself does not stabilise on `:6` within the wait window: escalate; do not start new revisions.
- Core is about to start on 8353cec4 and section 8.1 is not complete, or a Flyway V3 failure or partial V3 is seen.

## 8. Platform (Core and Gateway)

The Core trust-init container and `carelog-trust` volume change follow the same pattern against Core's current revision (merge, not replace). This document covers Carelog only. Platform owns the Core procedure.

Rollback targets for the platform services in DEV (read-only facts, 2026-11-24):

| Service | Live revision to roll back to | Image digest | Candidate for this change | Notes |
| --- | --- | --- | --- | --- |
| Core `ranikun-platform-dev-core` | `:3` | `sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001` (commit `39c5ccd4…`, PR #69) | `sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf` (commit `dc635694…`, PR #71) | Candidate applies Flyway V3 at startup (`evidence-flyway-v9.md` section 6.3). Rolling back the image does not undo V3. Service is desired 0 now. |
| Gateway `ranikun-platform-dev-gateway` | `:3` | `sha256:22267d151f3a4e88d85ce8bd7a0448d75a241fb9d82ecd943b4ca9280c61aa0f` | `sha256:1b00276e8e67e695f2753a6428fc576e351716c3687f22b9daf8e987508073d2` (same commit `dc635694…`) | Gateway `:3` keeps its cloudflared containers. Desired 0 now. |

Core's candidate is not part of the Carelog rollout. Do not roll Core back as part of a Carelog incident unless the Core owner asks for it. Core rollback to the previous image `ad9f8428` is verified only conditionally in an isolated environment (section 8.1, conditions C1 to C3); it is NOT verified on the real DEV database, roles, ALB/ECS health or secret injection. The Core task revision rollback is the Core owner's procedure.

### 8.1 Core V3 pre-start gate (mandatory for ANY start of Core on 8353cec4, enrollment on or off)

Why: the candidate Core image runs Flyway migration V3 at its first start, with no switch to skip it (`IdentityPersistenceConfiguration.java:110-112` calls `IdentityLegacySchemaGuard.migrate`, which calls `flyway.migrate()` at `IdentityLegacySchemaGuard.java:31`; platform-services `dc63569`; see `docs/handoff/evidence-flyway-v9.md` sections 6.2-6.3). The last recorded Flyway state of the DEV `identity` schema is **version 2** (2026-11-21). Starting the candidate with enrollment off still applies V3. Desired count stays **0** until every step below is recorded.

Steps (all read-only; the commands are listed here and are not run by this document):

1. **Read-only V3 status.** Run by the DB owner with a read-only role. The application secrets are not used. Queries (database `app`):
   ```sql
   SELECT version, description, success, installed_on FROM identity.flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;
   SELECT column_name FROM information_schema.columns WHERE table_schema = 'identity' AND table_name = 'password_credentials' AND column_name = 'credential_revision';
   SELECT to_regclass('identity.carelog_registration_operation') IS NOT NULL AS table_present;
   ```
   Expected before V3: top version `2` with `success` true; no `credential_revision` column; `table_present` false. Any other result is a stop (section 8.1 stop conditions).
2. **Record** the result with the check time in UTC (ISO-8601). Both values become the input `core_v3_db_change_approval.v3_state_checked_at` and the reference below.
3. **Approval.** An approved change id or URL is recorded as `core_v3_db_change_approval.reference`. Terraform checks only that the fields are present and not placeholders. It is a documentation gate, not proof of the database state. The DEV database owner and the Platform owner approve.
4. **Migration role versus runtime role: what is verified and what is not.**
   - Verified from the live task definition `ranikun-platform-dev-core:3` (environment and secret NAMES only): `PLATFORM_IDENTITY_DATASOURCE_USERNAME/PASSWORD` and `PLATFORM_IDENTITY_FLYWAY_DATASOURCE_USERNAME/PASSWORD` all reference the secret `ranikun/dev/shared-db-admin` (keys `username`, `password`). The live Core runtime, including its Flyway, therefore uses the shared database admin credential.
   - Not verified: which role owns schema `identity` and its tables, and whether the admin credential is that owner.
   - Consequence: the candidate runs V3 under the shared admin credential, so the runtime credential is effectively the owner. The candidate does not change this. The repository has no switch to run Flyway outside the application, so a **dedicated migration role or step needs a code change in platform-core** that is not done. Until it exists, the gate requires the DB owner's explicit decision to accept V3 under the shared admin credential. The ECS task and execution roles are not database principals; the database user comes only from the secret.
5. **Desired count.** The Core service stays at `desiredCount` 0 until steps 1 to 4 are recorded and approved. Check with `describe-services` before any change.
6. **Start.** Before any `register-task-definition` for Core, run the section 8.2 deploy-time check on the rendered task definition (mandatory). Then one Core task definition on the candidate digest, with the trust-init wiring from the reviewed platform inputs. Watch the Core log stream for the Flyway lines (`Migrating schema "identity" to version "3"` and a success line). Then repeat step 1: version 3, `success` true, `credential_revision` present, `table_present` true. Record the result.

Rollback implications:
- Rolling back the Core image to `ad9f8428` (live `:3`) does **not** undo V3. The history keeps version 3, and the DDL is not reversed (same rule as section 6, Database).
- Core rollback to `ad9f8428` has been verified **CONDITIONALLY in an ISOLATED environment only** (Docker, PostgreSQL 16.15, throwaway data; `docs/handoff/evidence-core-rollback-test.md`). Conditions: **C1** Flyway keeps the default `*:future` tolerance (no ignore-pattern override); **C2** if Flyway ever runs with the runtime role, that role keeps `SELECT` on `identity.flyway_schema_history`; **C3** V3 is not re-applied after the rollback (the previous Core ignores V3).
- **NOT verified on the real DEV**: Aurora, DEV roles and grants, data volume, ALB and ECS health, secret injection, and registration retry. The live Core runtime and Flyway credentials both reference `ranikun/dev/shared-db-admin` (names only), so C1 to C3 describe a future role split, not DEV today. Do not read the isolated result as a DEV result.
- Do not edit or delete V3 by hand as part of a rollback.

Stop conditions (Core V3, in addition to section 7):
- The step 1 result is not version 2 with `success` true before the start, or shows a partial V3 (column or table present without version 3).
- No approval reference, or no check time, or a placeholder value.
- The runtime-versus-migration question in step 4 has no owner decision.
- `desiredCount` is not 0 before the gate passes.
- A Flyway failure appears in the Core log: stop, do not restart in a loop, and escalate.

### 8.2 Core deploy-time digest check (mandatory, immediately before `register-task-definition` for Core)

Run after the rendered Core task definition JSON is final and before it is registered. Registration is not done by this step. The check reads the rendered file and the pushed trust-init image; it changes nothing in AWS.

Inputs:
- `<CORE_TD_JSON>`: the rendered Core task definition that will be registered (the `--cli-input-json` file from the reviewed Platform plan, kept in the private directory, never in Git).
- `<PUSHED_TRUST_REF>`: the trust-init image reference that was pushed, by digest (`<account>.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:<64 hex>`). Read it from the publish step output, not from a tag.
- `<LOCAL_TRUST_IMAGE>`: the same trust-init image, pulled read-only by digest (`docker pull <PUSHED_TRUST_REF>`, after an ECR login with a temporary config). Its label and layers are read; no secret is read.

Command (repository root):
```bash
sh candidates/carelog-tls/tests/check-core-digest.sh --taskdef "<CORE_TD_JSON>" "<PUSHED_TRUST_REF>" "<LOCAL_TRUST_IMAGE>"
```

Expected output and exit code (exit 0 only):
```
check-core-digest: PASS rendered task definition matches the pinned Core digest, the pushed trust-init digest and its wiring
```

What it asserts, all of them (key names only in messages):
1. Exactly one application container and exactly one `carelog-trust-init` container.
2. The application image is the pinned candidate digest `sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf`.
3. The `carelog-trust` volume is declared.
4. The init container image equals `<PUSHED_TRUST_REF>` and is digest-pinned.
5. The init container mounts `carelog-trust` at `/run/carelog-trust` with `readOnly` false.
6. The application container mounts `carelog-trust` at `/run/carelog-trust` read-only.
7. The application container depends on `carelog-trust-init` with condition `SUCCESS`.
8. The local trust-init image's base label `ranikun.carelog.core-base` and its layers equal the application image (the same checks as the positional mode).

Stop conditions (do not register; escalate to the Platform owner):
- Any non-zero exit, or a message other than the PASS line above.
- `<PUSHED_TRUST_REF>` is not a digest reference, or the local image cannot be pulled by that digest.
- The rendered file differs from the file the check read (re-run the check after any edit; the file is the one registered).

Enforcement points (added 2026-11-24; the manual command above stays the reference):
- `.github/workflows/dev-ecs-release.yml` deploy job: runs this check on the rendered task definition immediately before `register-task-definition` whenever the rendered task definition carries `carelog-trust-init` or the Core image changes. A Core image change also requires `core_v3_approval_ref`. The workflow re-renders the live task definition and replaces only the image, so it cannot add the trust-init wiring: a Core candidate can reach DEV only through the reviewed Platform Terraform plan, and this workflow fails closed for it.
- Platform Terraform (`environments/dev/platform`, `terraform_data.core_trust_init_gate` in `core_env.tf`): the plan is refused unless the candidate has exactly one `carelog-trust-init` container whose image equals `core_trust_init_pinned_ref` (the pushed digest from the trust-init build summary). The Core completeness gate (`enrollment_completeness`, `core_env.tf`) already enforces most of checks 2 to 7 on the input. Check 8 (base label and layers) needs Docker, so it stays in this script; the plan review must run section 8.2 before `apply`.
- Core Flyway V3 (Terraform): `core_v3_db_change_approval` remains a documentation gate. The Carelog `SPRING_FLYWAY_ENABLED` guard does not apply to Core.

Negative fixtures used to test this step (no secrets): `candidates/carelog-tls/tests/fixtures/core-taskdef-*.json`, with `tests/test-taskdef-check.sh` (13 checks, including the pushed-digest mismatch, the tag, the read-only init mount, the missing dependsOn, the missing volume, two application containers, and a trust-init image built on the live base).
