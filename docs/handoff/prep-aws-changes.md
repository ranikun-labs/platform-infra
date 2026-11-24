# AWS changes required for the Carelog DEV TLS candidate (prep, nothing executed)

Account 124495093425, ap-northeast-2. Every row is **not executed**. Prices are from the AWS Price List API on 2026-11-24 (see `prep-cert-secrets.md` section 6). "Sidecar Fargate" is an upper bound, applies only if the task size must grow, and is an assumption.

Status of this document: it is the **approval request** for AWS writes. AWS write scope is not approved yet. Nothing in this document may run until that approval is given.

## 1. Recommended design: 1-secret bundle, CA baked into the trust-init image

Differences from the 3-secret design (`prep-cert-secrets.md`) are in section 4.

## 2. Approval request: resource list (AWS writes)

| # | Resource (type) | Target ARN pattern | Action needed (who) | Permission scope for the change | One-time cost | Monthly cost (Seoul, assumed usage) | Owner, when |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | ECR repository `ranikun/carelog/tls-proxy` (IMMUTABLE, scan on push, AES256, lifecycle keep last 10) | `arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy` | `ecr:CreateRepository`, `ecr:PutLifecyclePolicy`, `ecr:PutImageScanningConfiguration` (platform owner) | Create only this repository | $0 | about $0.01 (75 MB) | Platform owner, before first push |
| 2 | ECR repository `ranikun/platform/core-trust-init` (same settings) | `arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init` | same as 1 | Create only this repository | $0 | about $0.10 (749 MB image, shared layers unknown) | Platform owner, before first push |
| 3 | Secret `ranikun/dev/carelog/enrollment-tls/server-bundle` (JSON with `tls_certificate`, `tls_private_key`; AWS managed key) | `arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-??????` | `secretsmanager:CreateSecret` on that name, `secretsmanager:PutSecretValue` on that name (operator, once per renewal) | Only this secret name. No read permission is needed to create it. **No `GetSecretValue` for anyone outside the Carelog execution role** | $0 | $0.40 | Security/operator, after the leaf is signed offline |
| 4 | Boundary v4 `dev-boundary/ranikun-carelog-dev-api-execution` | IAM customer managed policy (`arn:aws:iam::124495093425:policy/dev-boundary/ranikun-carelog-dev-api-execution`) | `iam:CreatePolicyVersion`, `iam:SetDefaultPolicyVersion` (boundary owner) | Add `TlsProxyImagePull`, `TlsProxyBundleRead`, `EnrollmentServiceRead` (see `prep-iam-boundary.md` section 9) | $0 | $0 | Boundary owner, before Carelog Terraform apply |
| 5 | Boundary v4 `dev-boundary/ranikun-platform-dev-core-execution` | `arn:aws:iam::124495093425:policy/dev-boundary/ranikun-platform-dev-core-execution` | same as 4 | Add `TlsTrustInitImagePull`, `EnrollmentServiceRead`. **No TLS secret** | $0 | $0 | Boundary owner, before Platform Terraform apply |
| 6 | OIDC publish role `ranikun-dev-carelog-tls-image-publish` (trust: `ranikun-labs/platform-infra`, environment `dev-carelog-tls-publish`) | `arn:aws:iam::124495093425:role/ranikun-dev-carelog-tls-image-publish` | `iam:CreateRole`, `iam:PutRolePolicy` (platform admin) | ECR push to rows 1 and 2 only, ECR pull of `ranikun/platform/core` (build base). No Secrets Manager, KMS, IAM or ECS | $0 | $0 | Platform owner, before the workflow is enabled |
| 7 | GitHub environment `dev-carelog-tls-publish` (required reviewers), vars `AWS_REGION`, `DEV_ECR_REGISTRY`, `DEV_TLS_IMAGE_PUBLISHER_ROLE_ARN` | GitHub repo settings (not AWS) | Repo admin | n/a | $0 | $0 | Repo admin |
| 8 | Terraform apply `environments/dev/carelog` (inline `terraform-*` execution policy, SG rule 8443 from Core SG, new proxy container, task revision) | IAM inline policy of `ranikun-carelog-dev-api-execution`; ECS task family `ranikun-carelog-dev-api`; SG | Deployer role (not ranikun-admin): `iam:PutRolePolicy` on the execution role, `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `ec2:AuthorizeSecurityGroupIngress` | Scoped to the two services | $0 | Sidecar Fargate upper bound about $11 per task if CPU/memory must grow (assumption, not verified). Likely $0 | Deployer, after rows 1 to 5 and reviewed plan |
| 9 | Terraform apply `environments/dev/platform` (Core init container, no CA secret) | Core execution inline policy; ECS task family `ranikun-platform-dev-core` | Deployer role, as row 8 | Scoped to the Core services | $0 | $0 (init runs once per task start) | Deployer, after rows 1, 2, 5 |
| 10 | Optional: CMK for the bundle secret (only if the security review requires it) | KMS key (new, alias) | `kms:CreateKey`, `kms:CreateAlias`, `kms:PutKeyPolicy` (security owner). Then `kms:Decrypt` in rows 4 and 5 | Key policy limited to the two execution roles with `kms:ViaService` | $0 | $1.00 per key-month + $0.03 per 10,000 requests | Security owner, before row 3 |
| 11 | Rollback operator permission set or policy (human role used for the bundle version stage and Carelog service rollback; source `candidates/carelog-tls/tests/iam/rollback-operator.json`) | `arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-??????` (stage move) and `arn:aws:ecs:ap-northeast-2:124495093425:service/*/ranikun-carelog-dev-api` (update). Explicit Deny on `ranikun/dev/carelog/enrollment-service-XXXXXX` | Platform admin: `iam:CreatePolicy`, `iam:AttachRolePolicy` or permission-set update (only after approval) | $0 | $0 | Platform owner, before the first rollback drill |

Row 11 changes nothing by itself. The Deny on the enrollment secret must be attached to the operator principal (see `prep-cert-secrets.md` section 11).

Not requested: ACM, ACM Private CA, ALB/ingress changes, any read of secret values, any change to existing secrets, any change to the existing enrollment Bearer secret (`ranikun/dev/carelog/enrollment-service-XXXXXX`, read-only use only).

Target ARN patterns use `??????` for the 6-character random Secrets Manager suffix. The real ARN (with suffix) is known only after row 3. Terraform inputs need the full ARN.

## 3. Totals (assumed usage, Seoul list prices 2026-11-24)

| Scenario | One-time | Monthly |
| --- | --- | --- |
| Recommended (1-secret, rows 1 to 9, no CMK) | $0 | about $0.52 (one secret $0.40, API about $0.005, ECR about $0.11). Plus Fargate only if the task size grows |
| Same with CMK (row 10) | $0 | about $1.52 |
| 3-secret fallback (rows 3 and 4 become three secrets and a 3-secret boundary) | $0 | about $1.33 |

## 4. 3-secret vs 1-secret: cost, permissions, replacement and rotation

| Topic | 3-secret | 1-secret (recommended) |
| --- | --- | --- |
| Secrets to create (row 3) | 3 (`server-cert`, `server-key`, `ca-cert`) | 1 (`server-bundle`) |
| Monthly secret charge | $1.20 | $0.40 |
| Secret API calls per task start | 3 (proxy 2, Core 1) | 1 (proxy 1, Core 0) |
| Carelog boundary (row 4) | Cert + key ARN patterns + enrollment | Bundle ARN pattern + enrollment |
| Core boundary (row 5) | CA ARN pattern + enrollment | enrollment only; no TLS secret |
| Core can read the server key? | No (denied) | No (denied; bundle is a different ARN) |
| Carelog can read the CA? | No (denied) | Not applicable (no CA secret) |
| Trust-init image | Generic, CA read at start | Built per CA (`CA_BUNDLE_SRC`), digest pinned |
| Leaf renewal | Two `PutSecretValue` calls (cert and key) that must land as a pair; skew possible | One `PutSecretValue` (pair in one version); then force a Carelog deployment |
| CA rotation | Secret change (`PutSecretValue` on `ca-cert`) and Core restart | New trust-init image build, Core rollout (two-CA bundle tested) |
| Replacement if a secret is deleted | Two or three ARNs in Terraform | One ARN in Terraform |
| Rollback | Previous secret version (`AWSPREVIOUS`) for each of the three; TD revision | Previous version of one secret; TD revision |
| Version pinning | Needs version-id per entry (TD revision per rotation) | Not needed: one read per start |

## 5. Ordering

Rows 3, 4, 5 and 10 (if chosen) in any order -> rows 1 and 2 -> row 6 and 7 -> image publish (digest recorded in `prep-images.md`) -> rows 8 and 9 -> task definition rollout (`carelog-tls-ecs-rollout-rollback.md`). Terraform plan must show no change for existing resources before apply.

## 6. Blocking inputs still missing (need AWS writes)

- Repository digests for `ranikun/carelog/tls-proxy` and `ranikun/platform/core-trust-init`.
- Real ARN (with suffix) of `server-bundle`.
- The real public CA bundle `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem` committed by its owner (the draft workflow fails closed without it).
- Boundary owner for rows 4 and 5.
- Real `terraform plan` against DEV state with the TLS inputs. Not run here (needs protected inputs).
