# Permissions boundary changes for the TLS candidate (proposal, not applied)

Status: **proposal only.** No IAM policy, role, or version was created, changed, or attached. Read-only calls only (`get-policy`, `get-policy-version`, `get-role`, `simulate-principal-policy`, `simulate-custom-policy`). Policy documents are not secrets. The saved copies are under the private scratch directory.

**Update 2026-11-24: boundary v4 for the 1-secret design (section 9) supersedes the 3-secret TLS statements in sections 4 and 5 where they differ.** Carelog reads one bundle secret; Core reads no TLS secret (the CA is baked into the trust-init image). The existing 3-secret statements are kept below for the fallback.

Note: the random six-character suffix of the enrollment secret ARN is shown as XXXXXX; use the real ARN from Secrets Manager metadata.

## 1. Current boundaries (read-only)

| Boundary policy (customer managed, path `/dev-boundary/`) | Default version | Allowed now (summary) | Used by role |
| --- | --- | --- | --- |
| `ranikun-carelog-dev-api-execution` | v3 | ECR pull `ranikun/carelog/api`; logs on `/ecs/ranikun-carelog-dev-api`; `GetSecretValue` on jwt, db-admin, redis, gateway-internal, product-claims | `ranikun-carelog-dev-api-execution` |
| `ranikun-carelog-dev-api-task` | v1 | Deny all (no task-role permissions) | `ranikun-carelog-dev-api-task` |
| `ranikun-platform-dev-core-execution` | v3 | ECR pull `ranikun/platform/core`; logs; `GetSecretValue` on jwt, db-admin, redis, gateway-internal, product-claims | `ranikun-platform-dev-core-execution` |
| `ranikun-platform-dev-core-task` | v1 | Deny all | `ranikun-platform-dev-core-task` |
| `ranikun-platform-dev-gateway-execution` | v1 | ECR pull `ranikun/platform/gateway`; logs; `GetSecretValue` on jwt, gateway-internal, redis, cloudflare tunnel token | `ranikun-platform-dev-gateway-execution` |
| `ranikun-platform-dev-gateway-task` | v1 | Deny all | `ranikun-platform-dev-gateway-task` |

Each execution role also has a Terraform-managed inline policy (`terraform-2026…`), which the module generates from `execution_secret_arns` and `additional_ecr_repository_arns`. Effective permission = inline policy AND boundary.

Observed: the Carelog and Core execution boundaries do **not** include `ranikun/dev/carelog/enrollment-service`. That is the enrollment credential both sides read in the candidate. This gap exists today and is not caused by the TLS work.

## 2. Simulation before any change

`simulate-principal-policy` on the role ARNs (identity + boundary):

| Role | Action | Resource | Decision now |
| --- | --- | --- | --- |
| Carelog execution | `secretsmanager:GetSecretValue` | existing jwt secret (control) | allowed |
| Carelog execution | `secretsmanager:GetSecretValue` | `ranikun/dev/carelog/enrollment-service-XXXXXX` | **implicitDeny** |
| Carelog execution | `secretsmanager:GetSecretValue` | planned `ranikun/dev/carelog/enrollment-tls/*` | **implicitDeny** |
| Carelog execution | `ecr:BatchGetImage` | planned `ranikun/carelog/tls-proxy` | **implicitDeny** |
| Carelog execution | `kms:Decrypt` | `key/*` | **implicitDeny** (not needed with AWS managed key) |
| Core execution | `ecr:BatchGetImage` | `ranikun/platform/core` (control) | allowed |
| Core execution | `ecr:BatchGetImage` | planned `ranikun/platform/core-trust-init` | **implicitDeny** |
| Core execution | `secretsmanager:GetSecretValue` | `ranikun/dev/carelog/enrollment-service-XXXXXX` | **implicitDeny** |
| Core execution | `secretsmanager:GetSecretValue` | planned `ranikun/dev/carelog/enrollment-tls/*` (CA) | **implicitDeny** |

So the planned TLS candidate would fail at ECS task start (image pull or secret fetch) without these boundary changes.

## 3. Who can change it (simulation only, not tried)

`simulate-principal-policy` for `AWSReservedSSO_RanikunDevAdmin_4892299a053c81d3` (the `ranikun-admin` identity):

| Action | Resource | Decision |
| --- | --- | --- |
| `ecr:CreateRepository` | `ranikun/carelog/tls-proxy` | allowed |
| `secretsmanager:CreateSecret` | `ranikun/dev/carelog/enrollment-tls/*` | allowed |
| `secretsmanager:GetSecretValue` | same (would read values, **not done**) | allowed (not exercised) |
| `iam:PutRolePolicy` | `ranikun-carelog-dev-api-execution` | allowed |
| `iam:CreatePolicyVersion` | `dev-boundary/ranikun-carelog-dev-api-execution` | allowed |
| `iam:SetDefaultPolicyVersion` | same | allowed |
| `iam:PutRolePermissionsBoundary` | the carelog execution role | **implicitDeny** |
| `kms:CreateKey` | `*` | allowed |
| `acm:ImportCertificate` / `acm-pca:CreateCertificateAuthority` | `*` | allowed (not needed in the chosen design) |

Caveats: identity simulation only. Service control policies and resource policies are not evaluated here, and the simulate call does not prove that the write would succeed. The `allowed` results mean the ranikun-admin identity **should** be able to make these changes. Confirm with a real change in the owner's process.

Owner: the boundary policies are not defined anywhere in this repository (checked with `grep -r dev-boundary`). The owner is whoever manages the `dev-boundary` policies in the account. The change is a new policy version, then `SetDefaultPolicyVersion`. Versions: the two Carelog and Core execution boundaries each have three versions (v1, v2, v3, checked with `list-policy-versions`). The limit is 5, so v4 fits without deleting anything. Rollback is `SetDefaultPolicyVersion` back to the previous default.

The Terraform inline policy update (for `execution_secret_arns` and `additional_ecr_repository_arns`) happens through the normal Terraform apply path, not by editing the boundary.

## 4. Proposed statement additions (JSON diff)

Statement additions only. Existing statements are unchanged. Resource ARNs use `??????`, which matches the 6-character random suffix that Secrets Manager adds to each ARN. Only the three secret ARNs that already exist are listed without patterns (`enrollment-service-XXXXXX`).

Carelog execution boundary `ranikun-carelog-dev-api-execution` (add to `Statement`):

```json
[
  {
    "Sid": "TlsProxyImagePull",
    "Effect": "Allow",
    "Action": [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ],
    "Resource": "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy"
  },
  {
    "Sid": "TlsProxySecretsRead",
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": [
      "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-cert-??????",
      "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-key-??????",
      "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-service-XXXXXX"
    ]
  }
]
```

Platform Core execution boundary `ranikun-platform-dev-core-execution` (add to `Statement`):

```json
[
  {
    "Sid": "TlsTrustInitImagePull",
    "Effect": "Allow",
    "Action": [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ],
    "Resource": "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init"
  },
  {
    "Sid": "TlsCaSecretRead",
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": [
      "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/ca-cert-??????",
      "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-service-XXXXXX"
    ]
  }
]
```

Notes on the diff:
- The Core role does **not** get `server-key`. The Carelog role does **not** get `ca-cert`. Keep it that way.
- `enrollment-service-XXXXXX` is added to both boundaries because both sides read it in the candidate. If the enrollment design changes so that only one side needs it, remove the other side's entry.
- No `kms:Decrypt` (AWS managed key). If a CMK is chosen, add `kms:Decrypt` with `Condition: {"StringEquals": {"kms:ViaService": "secretsmanager.ap-northeast-2.amazonaws.com"}}` and the key ARN, to both boundaries and to the Terraform `execution_kms_key_arns`.
- No task-role (`-task`) boundary change: the sidecar and the init container need no application permissions.
- Log delivery: both new containers log into the existing service log group, which is already covered by the boundary's `log-stream:*` resource. No change needed.
- Do not add these to the Terraform execution inline policy by hand; the module derives it from the inputs.

## 5. Offline check of the proposed boundaries (`simulate-custom-policy`, read-only)

The full proposed boundary document (existing plus additions) was tested with `simulate-custom-policy`. This only evaluates the boundary, not the Terraform inline policy.

| Boundary | Action and resource | Result |
| --- | --- | --- |
| Carelog | ECR `ranikun/carelog/tls-proxy` | allowed |
| Carelog | secret `server-cert-AbCdEf` (pattern test) | allowed |
| Carelog | secret `server-key-AbCdEf` (pattern test) | allowed |
| Carelog | secret `enrollment-service-XXXXXX` | allowed |
| Carelog | secret `ca-cert-AbCdEf` | implicitDeny (correct: Carelog must not read the CA) |
| Carelog | ECR `ranikun/carelog/api` (control) | allowed |
| Core | ECR `ranikun/platform/core-trust-init` | allowed |
| Core | secret `ca-cert-AbCdEf` | allowed |
| Core | secret `enrollment-service-XXXXXX` | allowed |
| Core | secret `server-key-AbCdEf` | implicitDeny (correct: Core must not read the server key) |
| Core | ECR `ranikun/platform/core` (control) | allowed |

The pattern test uses a sample suffix. The real suffixes are only known after creation, and `??????` must match them exactly (6 characters). Re-check with a real `simulate-principal-policy` after the change.

## 6. Who changes what, in order

1. Boundary owner: create v4 of the two boundaries (the JSON above), set it as default. Reviewer checks the diff. Rollback: set v3 as default.
2. Owner of the secrets: create the three secrets (`prep-cert-secrets.md`), then update the two patterns if the suffix assumption fails.
3. Publisher: create the two ECR repositories and push (`prep-images.md`).
4. Terraform apply for `environments/dev/carelog` and `environments/dev/platform` with the real ARNs and digests (the inline policy picks them up). Requires the Terraform deployer role, not the admin identity.
5. Task definition revision and service update through the reviewed rollout path (`carelog-tls-ecs-rollout-rollback.md`).

## 7. Open questions

1. Who owns the `dev-boundary` policies, and does a change need an extra approver?
2. Is `enrollment-service` needed by both roles? Today neither boundary allows it, so the enrollment path is blocked regardless of TLS.
3. Is a CMK required by the security review? If yes, add the KMS statements above and re-run the offline simulation.

## 8. Carelog TLS 3-secret vs 1-secret: boundary impact

| Statement (boundary) | 3-secret (sections 4 and 5) | 1-secret (section 9) |
| --- | --- | --- |
| Carelog `TlsProxyImagePull` (`ranikun/carelog/tls-proxy`) | Same | Same |
| Carelog `TlsProxySecretsRead` | `server-cert-??????`, `server-key-??????`, enrollment-service | **Replaced** by `TlsProxyBundleRead`: `server-bundle-??????` (one resource), enrollment-service kept |
| Core `TlsTrustInitImagePull` (`ranikun/platform/core-trust-init`) | Same | Same |
| Core `TlsCaSecretRead` (`ca-cert-??????`, enrollment-service) | Present | **Removed**. Core keeps only the enrollment-service read (`EnrollmentServiceRead`) |
| Secret ARNs allowed to Core | enrollment-service + CA | enrollment-service only |
| Secret ARNs allowed to Carelog | enrollment-service + cert + key | enrollment-service + bundle (bundle contains the key, the same trust boundary as before) |
| Secrets to create | 3 (`server-cert`, `server-key`, `ca-cert`) | 1 (`server-bundle`) |
| Secret ARN patterns in IAM | 3 TLS patterns | 1 TLS pattern |
| Rotation of IAM | Only if a secret name changes | Only if the bundle name changes. Secret value rotation needs no IAM change |

Required outcome checked: Carelog cannot read the CA (none exists in this design), Core cannot read the server key (the bundle is denied to Core).

## 9. Boundary v4 for the 1-secret design (simulation, read-only)

Files (private scratch, not in Git): `private/prep2-platform/v4-1secret-carelog-exec.json` and `v4-1secret-core-exec.json` (built from the current v3 documents in `private/prep-platform/`, adding statements only). The simulation used `aws iam simulate-custom-policy` with the wrapped policy arrays (`*.arr.json`). Sample suffixes (`AbCdEf`) stand in for the real 6-character suffix.

Statements added to the Carelog boundary (`ranikun-carelog-dev-api-execution`, v4):

```json
[
  {"Sid":"TlsProxyImagePull","Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],"Resource":"arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy"},
  {"Sid":"TlsProxyBundleRead","Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":["arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-??????"]},
  {"Sid":"EnrollmentServiceRead","Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-service-XXXXXX"}
]
```

Statements added to the Core boundary (`ranikun-platform-dev-core-execution`, v4):

```json
[
  {"Sid":"TlsTrustInitImagePull","Effect":"Allow","Action":["ecr:BatchCheckLayerAvailability","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],"Resource":"arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init"},
  {"Sid":"EnrollmentServiceRead","Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-service-XXXXXX"}
]
```

Simulation results (EvalDecision, `simulate-custom-policy`, 2026-11-24):

| Boundary | Action and resource | Expected | Result |
| --- | --- | --- | --- |
| Carelog | ECR `ranikun/carelog/api` (control) | allowed | allowed |
| Carelog | ECR `ranikun/carelog/tls-proxy` | allowed | allowed |
| Carelog | secret `server-bundle-AbCdEf` | allowed | allowed |
| Carelog | secret `enrollment-service-XXXXXX` | allowed | allowed |
| Carelog | secret `ca-cert-AbCdEf` (must deny) | implicitDeny | implicitDeny |
| Carelog | secret `shared-identity/jwt` (control) | allowed | allowed |
| Core | ECR `ranikun/platform/core` (control) | allowed | allowed |
| Core | ECR `ranikun/platform/core-trust-init` | allowed | allowed |
| Core | secret `server-bundle-AbCdEf` (must deny: server key) | implicitDeny | implicitDeny |
| Core | secret `ca-cert-AbCdEf` (no CA secret) | implicitDeny | implicitDeny |
| Core | secret `enrollment-service-XXXXXX` | allowed | allowed |
| Core | ECR `ranikun/carelog/tls-proxy` (must deny) | implicitDeny | implicitDeny |

Result: 12 of 12 match the expectation. Simulation covers boundary documents only. The Terraform inline policy (`terraform-*`) is separate and is generated from `execution_secret_arns` and `additional_ecr_repository_arns` (`environments/dev/platform/services.tf`, `environments/dev/carelog/main.tf`). Re-check the real ARNs with `simulate-principal-policy` after the secret exists.

Owner, cost and rollback: as in section 3 (new policy version, `SetDefaultPolicyVersion`, rollback to v3). Two boundaries, each with v1-v3 today, so v4 fits the 5-version limit.
