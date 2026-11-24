# Carelog TLS rollout and rollback (single-bundle design, draft, not executed)

Status: **no command in this document has been run.** Every command is a template. `<PLACEHOLDER>` values are filled only after owner approval. Secret values, tfvars, state, plan text and environment values never go into chat or Git.

Scope: the DEV service `ranikun-carelog-dev-api` (cluster `dev-shared`, account 124495093425, ap-northeast-2). Core and Gateway are out of scope except section 8.

## 0. Design this procedure assumes

- Proxy sidecar `carelog-tls-proxy` on 8080 (existing API allowlist) and 8443 (Core enrollment only).
- One Secrets Manager secret holds the server bundle as JSON (`tls_certificate`, `tls_private_key`). The sidecar reads it as **one** env var, `TLS_BUNDLE_JSON`, from a **bare ARN with no json-key and no version suffix**. There is no separate CA secret. The CA is baked into the Core trust-init image (see `docs/handoff/prep-cert-secrets.md`).
- The bundle secret is created and rotated by the owner, as described in `docs/handoff/prep-cert-secrets.md` section 3 (PutSecretValue, version rules, rollback to the previous version in section 3.4). This document does not repeat those commands.
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

1. **Stop traffic and return to `:6`.**
   ```bash
   aws ecs update-service --cluster dev-shared --service ranikun-carelog-dev-api \
     --task-definition arn:aws:ecs:ap-northeast-2:124495093425:task-definition/ranikun-carelog-dev-api:6 --desired-count 0
   aws ecs wait services-stable --cluster dev-shared --services ranikun-carelog-dev-api
   ```
   Then `describe-services`: `taskDefinition` `:6`, `desiredCount` 0, `runningCount` 0.
2. **Record** the rollback target `:6`, the candidate revision, the time, and the reason, in the operations log.
3. **Bundle, only if it was changed and must be reverted.** The `:6` revision does not use the bundle, so this step is needed only before any new candidate is started again. Recover the previous bundle **version** by following `docs/handoff/prep-cert-secrets.md` section 3.4 (move `AWSCURRENT` back to `PreviousVersion`). Do not duplicate its commands here. Do not touch any other secret.
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

## 8. Platform (Core and Gateway)

The Core trust-init container and `carelog-trust` volume change follow the same pattern against Core's current revision (merge, not replace). This document covers Carelog only. Gateway keeps its current configuration. Platform owns the Core procedure.
