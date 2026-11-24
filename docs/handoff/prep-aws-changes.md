# AWS changes required for the Carelog DEV TLS candidate (prep, nothing executed)

Account 124495093425, ap-northeast-2. Every row is **not executed**. Costs are assumptions dated 2026-11-24 (see `prep-cert-secrets.md`). "Sidecar Fargate" is an upper bound: it applies only if the task size must grow.

| # | AWS change | Target resource | Required permission (who makes it) | One-time cost | Monthly cost (assumed) | Who / when |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Create ECR repo `ranikun/carelog/tls-proxy` (IMMUTABLE, scan on push, AES256, keep last 10) | `arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy` | `ecr:CreateRepository`, `ecr:PutLifecyclePolicy` (ranikun-admin: allowed in simulation) | $0 | ~$0.01 storage | Platform owner, before first image push |
| 2 | Create ECR repo `ranikun/platform/core-trust-init` (same settings) | `arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init` | same as 1 | $0 | ~$0.10 storage | Platform owner, before first image push |
| 3 | Create OIDC publish role `ranikun-dev-carelog-tls-image-publish` (trust: repo `ranikun-labs/platform-infra`, environment `dev-carelog-tls-publish`) | IAM role (new) | `iam:CreateRole`, `iam:PutRolePolicy` (admin) | $0 | $0 | Platform owner, before the workflow is enabled |
| 4 | Create GitHub environment `dev-carelog-tls-publish` with required reviewers; set vars `AWS_REGION`, `DEV_ECR_REGISTRY`, `DEV_TLS_IMAGE_PUBLISHER_ROLE_ARN` | GitHub repo settings | Repo admin | $0 | $0 | Repo admin, before enabling workflow |
| 5 | Move `.github/workflows-draft/dev-carelog-tls-images.yml` to `.github/workflows/` | Repo file | PR merge (lead) | $0 | $0 | Lead, after 1 to 4 |
| 6 | Create secret `ranikun/dev/carelog/enrollment-tls/server-cert` (PEM, plaintext) | Secrets Manager (new ARN with suffix) | `secretsmanager:CreateSecret`, `secretsmanager:PutSecretValue` (admin: allowed) | $0 | $0.40 | Security/operator, after cert is signed offline |
| 7 | Create secret `ranikun/dev/carelog/enrollment-tls/server-key` (PEM, plaintext) | Secrets Manager (new ARN) | same as 6 | $0 | $0.40 | same as 6 |
| 8 | Create secret `ranikun/dev/carelog/enrollment-tls/ca-cert` (CA certificate only, never the key) | Secrets Manager (new ARN) | same as 6 | $0 | $0.40 | same as 6 |
| 9 | Create policy version v4 for `dev-boundary/ranikun-carelog-dev-api-execution` (add TLS proxy ECR pull and two secret ARNs) | IAM customer managed policy | `iam:CreatePolicyVersion`, `iam:SetDefaultPolicyVersion` (admin: allowed in simulation). Owner: boundary owner | $0 | $0 | Boundary owner, before Terraform apply for Carelog |
| 10 | Create policy version v4 for `dev-boundary/ranikun-platform-dev-core-execution` (add trust-init ECR pull, CA secret, enrollment secret) | IAM customer managed policy | same as 9 | $0 | $0 | Boundary owner, before Terraform apply for Platform |
| 11 | Add `ranikun/dev/carelog/enrollment-service` to both boundaries (if not already covered by 9 and 10) | Covered in 9 and 10 | same as 9 | $0 | $0 | Boundary owner (decision required, see prep-iam-boundary.md) |
| 12 | Terraform apply `environments/dev/carelog`: inline execution policy gets the new ECR and secret ARNs; SG rule for 8443 from Core SG; new containers in the task | IAM inline policy `terraform-*`, security group rule, new task revision | Terraform deployer role (not ranikun-admin) | $0 | $0 | Deployer, after 6 to 10 and a reviewed plan |
| 13 | Terraform apply `environments/dev/platform`: same for the Core execution role and the init container | same as 12 | Terraform deployer role | $0 | $0 | Deployer, after 6 to 10 and a reviewed plan |
| 14 | Register the reviewed Carelog task definition revision (proxy + app + volume, `dependsOn` none) and update the service through the rollout path | ECS task definition family `ranikun-carelog-dev-api`, service `ranikun-carelog-dev-api` | `ecs:RegisterTaskDefinition`, `ecs:UpdateService` (deployer) | $0 | Sidecar Fargate, upper bound ~$11 per task if task CPU/memory must grow from 0.25 vCPU / 0.5 GB (assumed Seoul Fargate rates, unverified). Likely $0 if current size is enough | Release owner, per `carelog-tls-ecs-rollout-rollback.md` |
| 15 | Register the reviewed Platform Core task definition revision (init container with `dependsOn` SUCCESS, shared volume read-only for app) and update the service | ECS task definition family for `ranikun-platform-dev-core`, service of same name | `ecs:RegisterTaskDefinition`, `ecs:UpdateService` (deployer) | $0 | Init container runs once per task start, no steady-state cost. Sidecar Fargate: none (init is not running after exit) | Release owner, same rollout as 14 |
| 16 | Publish images: push `ranikun/carelog/tls-proxy:git-<sha>` and `ranikun/platform/core-trust-init:git-<sha>`, record digests | ECR (rows 1 and 2) | Publisher role from row 3 (`ecr:PutImage` and related) | $0 | Included in rows 1 and 2 | Publisher workflow, after row 4 approval |
| 17 | Optional: customer managed KMS key for the three secrets (only if the security review requires it) | KMS key (new) + key policy | `kms:CreateKey`, `kms:CreateAlias`, `kms:PutKeyPolicy` (admin: allowed in simulation). Then `kms:Decrypt` in rows 9 and 10 | $0 | ~$1.00 | Security owner, before row 6 if chosen |
| 18 | Optional: enable ECR image scanning findings gate in the publish workflow | Workflow (repo file) | None (read only) | $0 | $0 | Lead, after first scan results |
| 19 | No change: ACM certificate, ACM PCA, ALB/ingress for the TLS path | n/a | n/a | $0 | $0 | Not needed for internal 8443 |

## Totals (assumed)

| Scenario | One-time | Monthly |
| --- | --- | --- |
| Recommended (rows 1 to 16, no CMK) | $0 | About $1.35 for 3 secrets and ECR, plus Fargate only if task size grows (upper bound about $11 per running task) |
| With optional CMK (row 17) | $0 | About $2.35 |
| If ACM PCA were chosen instead (rejected) | $0 | About $400 per CA plus per-cert fees |

## Blocking inputs still missing (need AWS writes)

- Repository digests for `ranikun/carelog/tls-proxy` and `ranikun/platform/core-trust-init` (row 16).
- Secret ARNs with suffixes for the three TLS secrets (rows 6 to 8). The Terraform inputs need them.
- Confirmation of the boundary owner for rows 9 to 11.
- Real `terraform plan` against the DEV state with the TLS inputs. Not run here, because it needs protected inputs.

## Ordering

6 to 8 and 9 to 11 (in any order) -> 1 and 2 -> 3 and 4 -> 5 -> 16 -> 12 and 13 -> 14 and 15. Terraform plan must show no-op for the existing resources before apply, as in the preserve handoff.
