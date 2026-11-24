# Evidence: Core candidate image `sha256:8353cec4…` and live Core `:3` image `sha256:ad9f8428…`

Status: read-only evidence, 2026-11-24. Sources: AWS ECR and ECS describe calls (`ranikun-admin`, ap-northeast-2), GitHub read calls (`gh run view/list`, `gh api` GET) on `ranikun-labs/platform-services`, and a shallow read-only clone of that repository in a private scratch directory. No secret values were read, no writes were made, and nothing was deployed.

## 1. Identifiers

| Item | Value | Evidence |
| --- | --- | --- |
| Core candidate digest | `sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf` (repo `ranikun/platform/core`) | `ecr describe-images --image-ids imageDigest=` |
| Candidate ECR tag | `dc63569471eea0499a2d15bb3bda4721233c4258-44921734845-1`, pushed `2026-11-21T16:01:53Z` | ECR `imagePushedAt` (`+09:00` local, converted) |
| Candidate publish run | `44921734845` "Platform services DEV release", `workflow_dispatch`, `headBranch` main, `headSha` `dc635694…`, created 2026-11-21T15:55:24Z, conclusion **success** | `gh run view` |
| Candidate source commit | `dc63569471eea0499a2d15bb3bda4721233c4258`, the squash merge of PR #71 ("Add internal Carelog registration coordination candidate"), merged 2026-11-21T13:38:38Z; PR head `2d5768222a0a` | `gh api repos/…/commits/dc635694/pulls` |
| Live Core digest (`:3`) | `sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001` | `ecs describe-task-definition ranikun-platform-dev-core:3` |
| Live ECR tag | `39c5ccd4146ff685459a84987461f7bda1a8421c-44773833065-2`, pushed `2026-11-20T16:36:32Z` | ECR |
| Live publish run | `44773833065`, `workflow_dispatch`, head `39c5ccd4…`, conclusion success, created 2026-11-20T16:29:02Z | `gh run view` |
| Live source commit | `39c5ccd4146ff685459a84987461f7bda1a8421c`, squash of PR #69 ("Redis ACL 인증으로 Identity 캐시 접근 제어"), merged 2026-11-20T16:28:40Z | `gh api …/commits/39c5…/pulls` |
| Gateway candidate (same SHA) | run `44921731287`, success; digest `sha256:1b00276e8e67e695f2753a6428fc576e351716c3687f22b9daf8e987508073d2`; deploy skipped; deployment `7965727836` (`dev-gateway-publish`) | run log line 16:00:18Z |
| Gateway live (`:3`) | `sha256:22267d151f3a4e88d85ce8bd7a0448d75a241fb9d82ecd943b4ca9280c61aa0f` (task def `ranikun-platform-dev-gateway:3`) | ECS |

## 2. Publish evidence (question i)

| Check | Candidate `8353cec4` | Live `ad9f8428` |
| --- | --- | --- |
| Publish job succeeded | **Yes** (`release / publish` success, run 44921734845) | **Yes** (run 44773833065) |
| Digest in publish log | **Yes**: `dc635694…-44921734845-1: digest: sha256:8353cec4…` at 2026-11-21T16:01:53Z; `exporting manifest list sha256:8353cec4…` at 16:01:42Z | **Yes**: `39c5ccd4…-44773833065-2: digest: sha256:ad9f8428…` at 16:36:32Z |
| ECR tag → digest | Tag maps to `8353cec4` (ECR tag mutability setting not checked) | Tag maps to `ad9f8428` |
| Tag SHA = run head SHA = source commit | **Yes**: `dc635694…` for all three (PR #71 squash commit) | **Yes**: `39c5ccd4…` (PR #69 squash commit) |
| ECR scan | Not available at publish ("ECR scan status: not available") | Same |
| Test job at dispatch SHA | success | success |
| **Verdict (i)** | **Proven**: image digest ↔ tag ↔ run ↔ source commit linkage is consistent. The source tree was not rebuilt here, so reproducibility of the digest is **unproven**. | Proven in the same sense |

## 3. Deploy approval (question ii)

| Check | Result |
| --- | --- |
| Deploy job in the candidate run | `release / deploy` **skipped** (run 44921734845); `deploy_enabled` was not set |
| Deployments for `dc635694…` | Only `dev-core-publish` (`7965740796`, 2026-11-21T15:59:38Z) and `dev-gateway-publish` (`7965727836`, 15:58:28Z). **No `dev-core-deploy` deployment for this SHA.** |
| Pending deployments / approvals for run 44921734845 | none (empty) |
| PR #71 reviews | **0 reviews** |
| Live `:3` deploy | Not checked in the candidate; live service `ranikun-platform-dev-core` is ACTIVE, desired 0, running 0, task def `:3`, PRIMARY COMPLETED |
| **Verdict (ii)** | **No deploy approval found** (no environment deployment, no reviewer approval, no PR review). Status: **no** for the candidate. |

## 4. What the candidate changes against live (compare API)

- `compare/39c5…dc63…`: status `ahead`, `ahead_by` 1, `behind_by` 0. The candidate is the live commit plus one squash commit (#71). 49 files changed.
- Added in Core (`platform-core/identity`):
  - Flyway migration `V3__carelog_registration_operation.sql`: adds `password_credentials.credential_revision bigint NOT NULL DEFAULT 0`, a trigger function `bump_credential_revision_on_password_change()` and trigger `password_credential_revision_trigger` (BEFORE UPDATE), and a new table `carelog_registration_operation` (operation_key uuid PK, account_id FK → platform_accounts, state CHECK in PENDING/COMPLETED/CONFLICT, timestamps).
  - Enrollment client, enabled only when `platform.identity.carelog-enrollment.enabled=true`: `CarelogEnrollmentClientConfiguration.java:15` (`@ConditionalOnProperty`), `CarelogEnrollmentProperties.java:8` (`prefix = "platform.identity.carelog-enrollment"`), `CarelogEnrollmentHttpAdapter.java:16` path `/api/v1/internal/v1/identity/carelog/enrollments/{accountId}` (PUT). This matches the Carelog 8443 route.
  - Registration endpoint `POST /api/v1/auth/carelog/registration` (`CarelogRegistrationController.java:30,35`), enabled only when `platform.identity.carelog-registration.enabled=true` (`CarelogRegistrationHttpConfiguration.java:15`, `CarelogRegistrationCompositionConfiguration.java:25`).
  - Coordinator and store: `CarelogRegistrationCoordinator`, `CarelogRegistrationStore`; `IdentityLegacySchemaGuard` / schema constants list `carelog_registration_operation` as an Identity table.
- Dev-only composition: `CarelogRegistrationCompositionConfiguration.requireDevComposition` (called at line 32) fails unless the active profile is `dev`, not production, `platform.identity.auth.enabled=true`, `platform.identity.persistence.enabled` (default true), and `platform.identity.carelog-enrollment.enabled=true`. So the "dev profile dependency" is real and enforced at startup.
- Gateway (`gateway-app`): `CarelogRegistrationCorsConfiguration`, `RegistrationCanonicalPathFilter`, +17 lines in `application.yml`, and changes to `JwtGlobalFilter`, `AuthPublicRequestMatcher`, `OAuthPublicRequestMatcher`, `GatewayConfig`.
- Enrollment client code is present in `8353cec4` (the source of the candidate image). It is not present in `ad9f8428` (live).
- Live `:3` environment (non-secret names checked): `PLATFORM_IDENTITY_AUTH_ENABLED=true`, `PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED=true`, `PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL` (Carelog 8080). No `carelog-registration` or `carelog-enrollment` setting. Registration and enrollment are off on live.

## 5. Gaps and open items

- Whether the image `8353cec4` was built from exactly `dc635694` is shown by the tag and run metadata, not by a rebuild.
- No environment or PR approval for deploying the candidate was found. A deploy needs a separate, approved action.
- The candidate's Core migration V3 runs automatically at Core startup (see `evidence-flyway-v9.md`). This is a DEV database change on the first start of the candidate, with no approval gate in the repository.
- Gateway candidate `1b00276e…` was built from the same commit but is outside this evidence's scope beyond the digest.

## 6. Commands (for reviewers)

```powershell
aws ecr describe-images --repository-name ranikun/platform/core --image-ids imageDigest=sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf --profile ranikun-admin --region ap-northeast-2
gh run view 44921734845 -R ranikun-labs/platform-services --log | Select-String 'digest: sha256'
gh api repos/ranikun-labs/platform-services/commits/dc63569471eea0499a2d15bb3bda4721233c4258/pulls
gh api repos/ranikun-labs/platform-services/deployments/7965740796
gh api repos/ranikun-labs/platform-services/compare/39c5ccd4146ff685459a84987461f7bda1a8421c...dc63569471eea0499a2d15bb3bda4721233c4258 --jq '.status,.ahead_by,.behind_by'
```

