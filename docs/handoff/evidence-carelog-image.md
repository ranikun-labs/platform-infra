# Evidence: Carelog image `sha256:2630045e…` (DEV candidate) and live `:6` digest `sha256:7dd7b858…`

Status: read-only evidence collected 2026-11-24 with `gh` (GET only) and AWS describe/list calls. No writes, no secrets read.
Scope: what is proven about the publish, the source commit, and any DEV deploy approval. Nothing here authorizes a deploy.

## Identifiers

| Item | Value |
| --- | --- |
| "#61" | **PR #61** in `ranikun-labs/carelog-be` ("Verify Carelog identity migrations through V9"). Not an issue, and not a workflow run number. The release run is run_number 3 (databaseId 45136354872). |
| PR #61 head | `e1f994c2c347e1da8b6792cc96e4aa90abdf2c18` (branch `codex/carelog-v9-migration-ci-20261123`) |
| PR #61 merge | `5d6aa88cdf44d01ca07a8fa8265a8c7cb0c2a995` (merge commit on `dev`, parents `8617838e…` and `e1f994c2…`), merged 2026-11-23T08:09:16Z by `aixion1506` |
| Publish run | https://github.com/ranikun-labs/carelog-be/actions/runs/45136354872 (workflow "Carelog DEV release", file `.github/workflows/dev-release.yml`, event `workflow_dispatch`, actor `aixion1506`, head_sha `5d6aa88c…`, branch `dev`) |
| Candidate tag | `5d6aa88cdf44d01ca07a8fa8265a8c7cb0c2a995-45136354872-1` in ECR `ranikun/carelog/api` (IMMUTABLE tags, AES256, scan-on-push enabled), pushed 2026-11-23 17:13:55 KST |
| Candidate digest | `sha256:2630045e50b01879b0d3462fcd38509b9255131af52928e3a04878c6ade11d39` |
| Live `:6` image | `sha256:7dd7b858abb0fe701d2ac3a5c6cd25bfedea7efdc1a7f47fdc28362961561e54`, ECR tag `318e1afe23a6471c7d7622cdcb7318f9885b0dd5-44706998265-1`, pushed 2026-11-20 18:04 KST |

## (i) Publish and digest linkage

| Question | Answer | Evidence |
| --- | --- | --- |
| Did the publish succeed? | **Yes** | Run 45136354872 conclusion `success`. Job `release / publish` (job 137564684515) success, step "Build and publish immutable image" success. Job `test` (137563475952) success. |
| Is the digest in the publish logs? | **Yes** | Log of run 45136354872: `5d6aa88c…-45136354872-1: digest: sha256:2630045e50b01879b0d3462fcd38509b9255131af52928e3a04878c6ade11d39 size: 856`, and buildx `exporting manifest list sha256:2630045e…`. The step also runs `aws ecr describe-images --image-ids imageTag=<tag>` and writes `image=<registry>/<repo>@sha256:…` to `GITHUB_OUTPUT`. |
| Does ECR map the tag to that digest? | **Yes** | `describe-images` (ap-northeast-2): tag `5d6aa88c…-45136354872-1` → digest `sha256:2630045e…`. Tag is IMMUTABLE, so the mapping cannot be re-pointed. |
| Is the tag's SHA prefix the source commit? | **Yes** | Tag prefix `5d6aa88cdf44d01ca07a8fa8265a8c7cb0c2a995` = run head_sha = PR #61 merge commit. `gh api repos/ranikun-labs/carelog-be/commits/5d6aa88c…` resolves on `dev`. |
| Which code was built? | The `test` job checked out `5d6aa88c` and verified `git rev-parse HEAD`. The publish job checked out `test_sha` = `github.sha` (validated equal). The merge commit contains PR #61 head `e1f994c2`. | Job `test` step "Verify source SHA" success; release workflow input validation. |
| ECR scan status | Not available at publish time (log line "ECR scan status: not available"). | Log line 708. |
| Digest linked to source SHA | **Proven** (tag ↔ digest ↔ run ↔ commit). | Items above. |

Verdict (i): **publish succeeded; digest ↔ source SHA linkage proven.** The image was built from PR #61's merged code. Note that the release workflow's `deploy` job was skipped in this run (see ii).

## (ii) Deploy approval status for the candidate digest

| Question | Answer | Evidence |
| --- | --- | --- |
| Was the candidate deployed to DEV by its run? | **No.** Run input `deploy_enabled: false` (log line 293, workflow default). Job `release / deploy` = `skipped`. | Run 45136354872 jobs. |
| Any DEV deployment record for `5d6aa88c`? | Only `dev-carelog-publish` (id 7993603407, created 2026-11-23T08:12:25Z). No `dev-carelog-deploy` deployment for this SHA. | `gh api repos/ranikun-labs/carelog-be/deployments`. |
| Environment approval? | **None found.** `dev-carelog-deploy` and `dev-carelog-publish` have only a `branch_policy` rule (no required reviewers). `pending_deployments` and `approvals` for run 45136354872 are empty. | `gh api repos/.../environments/...`, `.../actions/runs/45136354872/pending_deployments`. |
| PR approval? | **None.** PR #61 has 0 reviews, `reviewDecision` empty, 0 issue comments. Branch protection on `dev`: `required_approving_review_count` 0, no required status checks. Merged by the PR author. | `gh pr view 61`, `gh api repos/.../pulls/61/reviews`, `gh api repos/.../branches/dev/protection`. |
| Required CI checks | The only check on the PR head was `customer-api-testcontainers` (workflow "RPL-64 Carelog Customer API database integration", run 45103235748, success) on `e1f994c2`. Not a required check. | `statusCheckRollup`. |
| Any AWS-side approval record (ECS, CloudTrail-like metadata)? | Not checked here. `describe-services` shows the live service still on `:6` (desired 0), so **no deploy of 2630045e has happened**. | `aws ecs describe-services --cluster dev-shared --services ranikun-carelog-dev-api`. |

Verdict (ii): **no evidence that anyone approved deploying `sha256:2630045e…` to DEV.** The deploy approval status is "unknown or none"; the only proof is the absence of approvals and the skipped deploy job. Any deploy must be a separate, explicitly approved action.

## Live `:6` digest `sha256:7dd7b858…` (comparison)

| Question | Answer | Evidence |
| --- | --- | --- |
| Which commit built it? | **`318e1afe23a6471c7d7622cdcb7318f9885b0dd5`**, via tag `318e1afe…-44706998265-1`. The tag is the name the release workflow gives, so the digest is traceable to that commit. | ECR `describe-images`; release run https://github.com/ranikun-labs/carelog-be/actions/runs/44706998265 (run_number 1, `test` and `release / publish` success, `release / deploy` skipped, 2026-11-20 09:00 UTC). |
| Who registered revisions `:5` and `:6` that use it? | **Unknown.** `:5` registered 2026-11-21 12:13 KST, `:6` registered 2026-11-21 12:17 KST. No carelog-be or platform-infra workflow run falls in that window that deploys this digest (run 44706998265 deploy was skipped; run 44921737873 at 2026-11-21 15:55 UTC is a different SHA and failed). | `describe-task-definition`; `gh run list` for both repos. |
| Is `318e1afe` an ancestor of the candidate `e1f994c2`? | **Yes.** The `:6` build SHA is an ancestor of the candidate. Between them the only HTTP surface change is the new `EnrollmentController` and `EnrollmentSecurityConfiguration` (internal enrollment, enabled only by `carelog.identity.enrollment.enabled=true`), plus migration `V9__external_account_projection.sql`. | `git diff 318e1afe e1f994c2` in a private partial clone. |

## Risks the lead should weigh (from this evidence)

1. **Schema.** The candidate adds migration `V9` (`ALTER TABLE users ADD COLUMN external_account_id`, new table `external_manager_projection_receipts`, new CHECK constraint). The app runs with `ddl-auto: validate`. The DEV release guard requires `SPRING_FLYWAY_ENABLED=false`, so the image will not migrate DEV. Whether DEV's database already has V9 is **unknown**; it was not queried. Rolling back the image does not reverse DDL.
2. **Same digest, different config.** `:5` and `:6` use the same digest as each other, so the digest alone does not show the configuration in use.
3. **Release guard on `:6`.** `:6` lacks `SPRING_FLYWAY_ENABLED` (it has `CARELOG_FLYWAY_ENABLED=false`). The release workflow would refuse to deploy an image revision based on `:6`. See `docs/handoff/evidence-8080-api.md`.

## Open questions

- Who or what registered `:5`/`:6` on 2026-11-21 (no matching GitHub run)?
- Is V9 applied to the DEV database? (Needs read access to `flyway_schema_history` or the schema; not attempted.)
- Is there an approval outside GitHub and AWS metadata (chat, ticket) for DEV deployment of `2630045e…`? None is recorded in the repositories checked.
- ECR scan result for `2630045e…` was not available at publish time; current scan status was not queried.

## 8. 2026-11-24 candidate task configuration corrections (no AWS writes)

Changes made to the candidate inputs (TLS secret and certificate references untouched):

| Item | Change | File |
| --- | --- | --- |
| (a) enrollment flag | `CARELOG_IDENTITY_ENROLLMENT_ENABLED=true` added to the app env in `task-fragments.json` (it was already in the tfvars example). Terraform merges `enrollment_tls_candidate.environment` into the app `environment` (`environments/dev/carelog/main.tf` `local.app_environment`) and the output `app_environment` exposes it for tests. | `candidates/carelog-tls/task-fragments.json`, `carelog.tfvars.example`, `environments/dev/carelog/main.tf`, `outputs.tf`, `tests/contract.tftest.hcl` |
| (b) proxy logConfiguration | `awslogs`, group `/ecs/ranikun-carelog-dev-api`, region `ap-northeast-2`, stream prefix `tls-proxy`. | same as above |
| (c) proxy healthCheck | `CMD-SHELL` `kill -0 $(cat /run/nginx.pid) || exit 1`, interval 30, timeout 3, retries 3, startPeriod 10. Mirrors the Dockerfile HEALTHCHECK, which ECS ignores. Verified in the built image (§9). | same as above |
| (d) app portMappings | `app_port_mappings = []` (already in tfvars; added to fragment context). Tests assert the value reaching the module is an explicit empty list. Module `modules/ecs-service/main.tf` line 128 emits 8080 only when the value is null. | tests |
| Flyway | `SPRING_FLYWAY_ENABLED=false` added as a plain env in both files (the guard in `dev-ecs-release.yml` lines 131-133 requires it). Details in `evidence-flyway-v9.md`. | `task-fragments.json`, `carelog.tfvars.example` |
| nginx | `merge_slashes off;` in both server blocks (found by §9 test). | `candidates/carelog-tls/nginx.conf` |

Test results:

| Command | Result |
| --- | --- |
| `docker build -t carelog-dev-tls-candidate:local candidates/carelog-tls` | exit 0 (rebuilt after nginx change) |
| `docker run ... carelog-dev-tls-candidate:local /tmp/test-proxy.sh` (test-proxy.sh mounted) | exit 0, PASS, 65 ok, 0 FAIL |
| `terraform.exe fmt -check -recursive environments/dev/carelog` | exit 0 (after `fmt` on `tests/contract.tftest.hcl`) |
| `terraform.exe init -backend=false -input=false` then `validate` | Success, configuration valid |
| `terraform.exe test` in `environments/dev/carelog` | Success, 4 passed, 0 failed |
| `terraform console -var-file` on the merged tfvars (scratch copy without backend) | evaluates as expected (see §10 of evidence-8080-api.md) |

Module changes needed: none for (a)-(d). The module passes raw containers and env through. Optional hardening only: change the module default for `app_port_mappings` from null to `[]` (not done; would change the module, which is out of scope).

Known gaps not closed here:
- Proxy healthCheck checks the nginx master process, not that the listeners answer. A listener-level check needs a path that the proxy allows (for example `GET /api/v1/health` through 8080 would hit the app and fail while the app is starting, so it was not chosen).
- Terraform plan against real DEV state and the protected inputs was not run (needs protected inputs and backend access; lead's step).
- `environments/dev/carelog/.terraform.lock.hcl` was already modified in the worktree before this work (`git status`), and `terraform init` may touch it again. Not committed by this task.

## 9. 2026-11-24 B2 update

The proxy healthCheck described in section 8 (kill -0 only) was replaced. The current command proves both task-IP listeners, the app listener, the served certificate against the file, and the loopback liveness route; startPeriod is 300 s. See evidence-8080-api.md section 11.

