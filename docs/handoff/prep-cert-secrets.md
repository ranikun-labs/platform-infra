# Carelog DEV enrollment TLS: certificate, key and CA storage (single bundle)

Status: **design and local tests only.** No secret, certificate, key, or CA was created, read, or changed in AWS. AWS calls were read-only (describe, list, `simulate-custom-policy`, Price List API, and an ECR pull of the Core image). Nothing was committed. Local tests use throwaway material generated in a temporary directory and removed afterwards.

Pins (2026-11-24):
- **Candidate Core image (enrollment-capable): `ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf`.** ECR describe-images: pushed 2026-11-22 01:01 JST, tag `dc63569471eea0499a2d15bb3bda4721233c4258-44921734845-1` (platform-services commit `dc63569`, 2026-11-21, "Add internal Carelog registration coordination candidate (#71)"), 249,583,092 bytes, no scan result.
- **Live Core image (task definition `ranikun-platform-dev-core:3`): `sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001`.** Not changed by this work. It is the live reference for the "existing CA store preserved" and negative tests.

Prices were fetched on **2026-11-24** from the AWS Price List API (section 6).

## 0. Decision summary

| Question | 3-secret (fallback only, section 13) | 1-secret bundle (recommended) |
| --- | --- | --- |
| Secrets Manager secrets | 2 for the leaf (`server-cert`, `server-key`) plus the CA handling | 1: `ranikun/dev/carelog/enrollment-tls/server-bundle` (JSON: `tls_certificate`, `tls_private_key`) |
| CA certificate | Read by Core from a secret (not recommended) | **Public PEM baked into the trust-init image** (build input, never a secret) |
| Reads per task start | Proxy 2 (cert and key), Core 1 (CA) | Proxy 1 (bundle), Core 0 for TLS |
| Version skew between cert and key | Possible (two reads) | **Impossible** (one read, one version) |
| Core can read the server key? | No (boundary denies) | No (boundary denies the bundle) |
| Monthly cost (DEV, section 5) | about $1.22 | about $0.41 (secret and API) |
| Rollback of the certificate | Per-secret stage moves (two, must match) | **One stage move on the bundle**, then a forced deployment |
| Enrollment Bearer secret | `ranikun/dev/carelog/enrollment-service-XXXXXX`, separate and unchanged | Same |

## 1. Certificate authority, certificates and algorithm

- **CA** (offline, operator workstation): ECDSA P-256, self-signed, `basicConstraints=critical,CA:TRUE`, `keyUsage=critical,keyCertSign,cRLSign`. The CA private key is never stored in AWS, the image, or Git.
- **Leaf** (proxy): ECDSA P-256, `basicConstraints=CA:FALSE`, `keyUsage=digitalSignature`, `extendedKeyUsage=serverAuth`, 180 days. The SAN must contain `DNS:ranikun-carelog-dev-api.dev.internal` (the name Core connects to). The entrypoint checks it exactly (section 4.1).
- Throwaway tests use ECDSA P-256 for all material.

## 2. Layout (single bundle)

| Item | Value |
| --- | --- |
| Secret name | `ranikun/dev/carelog/enrollment-tls/server-bundle` |
| Secret type | SecretString, JSON object with two keys |
| Keys | `tls_certificate` (one leaf certificate PEM), `tls_private_key` (leaf private key PEM, unencrypted) |
| Container env | `TLS_BUNDLE_JSON` = the whole secret string (**bare ARN, no json-key, no version-id**) |
| Read by | Carelog execution role (proxy container) only |
| Encryption | AWS managed key `aws/secretsmanager` (no CMK; same as the other `ranikun/dev/*` secrets) |
| Size | about 1.5 KB for one ECDSA leaf (limit 64 KB) |

Why one env var with the bare ARN: ECS fetches each `valueFrom` separately. One env var with no json-key means one `GetSecretValue` for the whole secret, so the certificate and the key always come from the same version.

PEM newlines are stored as `\n` escapes inside the JSON string. The bundle is built with `jq -c --rawfile` and parsed with `jq -ej` (section 4.2).

## 3. Operations

### 3.1 Renewal (new leaf)

1. Generate a new key and CSR offline, sign with the offline CA, check `openssl verify`, the SAN and the expiry.
2. Build the bundle from files (section 11.1) and run `PutSecretValue` once. Both keys move in one version.
3. ECS reads `AWSCURRENT` when a container starts. Running tasks keep the old pair. Force a new deployment of `ranikun-carelog-dev-api`. No task definition change is needed for the same ARN.
4. The proxy refuses to start with a bad pair, an expired or wrong-name leaf, or a CA certificate in the leaf slot (section 4.1). Then verify the served certificate fingerprint (section 3.3 step 4).

### 3.2 CA rotation (baked CA)

The CA is `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem` (public, committed by the CA owner), baked by `Dockerfile.trust` through `CA_BUNDLE_SRC`. Rotation:
1. Put the new CA next to the old one in the bundle (two certificates). Build and publish the trust-init image (workflow `dev-carelog-tls-images`). Record its digest.
2. Register a new Core task definition revision with the new init digest and roll Core. Each Core task now trusts both CAs.
3. Re-issue the leaf under the new CA and do the renewal (3.1).
4. After every Carelog task serves the new leaf, rebuild the trust image with the new CA only and roll Core again.

Tested (section 4.3): the store grows by exactly the number of CA certificates, on the candidate base (8353cec4) and on the live base (ad9f8428). A client trusts a leaf from either CA while both are in the store, and rejects a CA2 leaf when only CA1 is present.

### 3.3 Rollback of the certificate (single bundle)

The rollback of a certificate is **one operation on the bundle**: restore the previous version of the single bundle, then force a new deployment. The bundle holds the matching key, so the rollback moves the pair together.

1. Find the versions: `aws secretsmanager describe-secret --secret-id <BUNDLE_ARN> --query VersionIdsToStages`. Record the version id that carries `AWSCURRENT` (the bad one) and the one that carries `AWSPREVIOUS` (the last good one).
2. Move the stage back: `aws secretsmanager update-secret-version-stage --secret-id <BUNDLE_ARN> --version-stage AWSCURRENT --move-to-version-id <previous-version-id> --remove-from-version-id <current-version-id>`. Do not delete the bad version.
3. Force a new deployment of `ranikun-carelog-dev-api` (`aws ecs update-service ... --force-new-deployment`). New tasks read the previous version at start. Old tasks are replaced by the rolling deployment.
4. Verify the **served certificate fingerprint**: from a Core task, `openssl s_client -connect <task-ip>:8443 -servername ranikun-carelog-dev-api.dev.internal </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256` must equal the SHA-256 fingerprint of the leaf in the previous version (computed from the recorded leaf before the change, `openssl x509 -noout -fingerprint -sha256`). Also check the proxy log shows `test is successful`.
5. Use section 11.3 for the task definition rollback (previous revision) only when the fault is in the container, not in the certificate.

Operator permissions for 2 and 3: `tests/iam/rollback-operator.json` (no Allow on the enrollment secret, explicit Deny on it).

### 3.4 Pinning and the json-key form

Not used. If it were, each `valueFrom` would need `:<json-key>::<version-id>`, pinning a version-id in the Terraform-managed task definition. Every rotation would need a new revision. The ECS docs (secrets-envvar-secrets-manager, fetched 2026-11-24) allow a version-id but not together with a version-stage. This is why the bare ARN is used.

## 4. Local checks (throwaway material, Docker Desktop 29.7.2)

All checks are portable scripts in `candidates/carelog-tls/tests/`. `tests/run-all.sh` builds the images (proxy from `Dockerfile`, trust-init from `Dockerfile.trust` on the candidate and on the live base), generates throwaway material in a temporary directory, runs every check, lint and Terraform (when `TERRAFORM` is set), and removes the material. Per-check PASS/FAIL lines are printed. Counts from the final run are in section 4.6.

### 4.1 Proxy: entrypoint validation (`proxy-entrypoint.sh`, `tests/test-proxy-entrypoint.sh`)

Order of checks (no metadata call before them): JSON object; `tls_certificate` and `tls_private_key` non-empty strings; the certificate field holds exactly one certificate and no private key; the key field holds no certificate; `openssl x509` and `openssl pkey` parse; basicConstraints `CA:FALSE` (a CA in the leaf slot is a swap); `-checkend 0` (not expired); SAN check; pair check (SPKI hashes equal). Only the check name is printed, never a value.

SAN check (exact, after normalisation):
- The expected name (`TLS_EXPECTED_DNS_SAN`, default `ranikun-carelog-dev-api.dev.internal`) must be a plain DNS name: letters, digits, `.` and `-` only. Anything else (wildcard, space, newline, regex characters, empty) fails with "not a plain DNS name". It is lower-cased and a trailing dot is removed.
- The certificate's SAN entries are split on commas. Only `DNS:` entries are compared, as whole values after lower-casing and trailing-dot removal. No substring, prefix, suffix or wildcard matching. IP and other SAN types never match.

Test cases (16 + SAN cases, all PASS on the final run):

| Case | Expected |
| --- | --- |
| 1-secret matching bundle; second leaf (CA2-signed); 3-secret matching pair | start, `nginx -t` ok |
| mismatch, expired, CA in leaf slot (swap), fields swapped (key in cert field and the reverse), chain in cert field, non-PEM cert, no key, non-JSON, skew (cert from one leaf and key from another), no input | refused with the named check |
| SAN case-insensitive (`RANIKUN-...`) and trailing dot on the certificate name; list with the name among other entries | pass |
| SAN prefix (`x.name`), suffix (`name.evil`), wildcard certificate, IP-only certificate | refused ("SAN") |
| expected name: substring (`carelog-dev-api.dev.internal`), wildcard (`*.dev.internal`), newline injection, regex (`ranikun.*`) | refused (SAN or "not a plain DNS name") |
| expected name: upper case | matches |

### 4.2 Injection and JSON encoding (`tests/test-injection.sh`)

The bundle is passed as ECS passes it: one env var with the raw SecretString containing escaped newlines (`docker run -e`), and as an env-file line. The certificate and key are decoded with `jq -ej` and compared byte for byte with the originals: PASS for both. Refused: raw PEM in the variable, double-escaped `\\n`, a JSON array, a missing key (no key body in logs).

### 4.3 Core trust-init (`Dockerfile.trust`, `trust-init.sh`, `tests/test-trust-init.sh`, `tests/test-trust-jdk.sh`)

Base: the candidate Core (`8353cec4`), and the live Core (`ad9f8428`) as the live reference (both pulled read-only from ECR; the store is the Core image's own `cacerts`, PKCS12).

| Check | Result |
| --- | --- |
| Base store: all aliases of the base image's own store are kept, store grows by exactly the number of imported CAs (computed from the base, not hard-coded) | PASS on both bases |
| 1-CA baked bundle; 2-CA bundle (rotation overlap) | PASS |
| Negative bundles: empty, non-PEM text, stray text line, private key, leaf (non-CA), expired CA, missing path | refused, no `cacerts` left in the volume |
| JDK client in the Core-based image, store from trust-init, CA1 leaf by name | handshake ok (HTTP 403 from the allowlist) |
| CA1-only store with a CA2 leaf | rejected |
| 2-CA store with a CA2 leaf | ok |
| Default store only (no trust-init), CA1 leaf | rejected |
| Name mismatch (connect by IP, no IP SAN) | rejected |

### 4.4 Core image and trust-init base (`check-core-digest.sh`, `tests/test-core-digest.sh`)

See section 10. Results: PASS for the candidate; FAIL (as required) for the live base used as candidate, the candidate base used as live, a forged label on the live base, a non-digest reference, and the pinned check when the live digest is given.

### 4.5 Lint

| Tool | Scope | Result |
| --- | --- | --- |
| hadolint | `Dockerfile` (proxy), `Dockerfile.trust` (with the documented DL3002/DL3066 ignores) | PASS |
| shellcheck `-x -P SCRIPTDIR -s sh` | `trust-init.sh`, `proxy-entrypoint.sh`, every `tests/*.sh` | PASS |
| actionlint | `.github/workflows-draft/dev-carelog-tls-images.yml` | PASS |

### 4.6 Final run (2026-11-24, `RUN_AWS_SIM=1 TERRAFORM=... AWS_PROFILE=ranikun-admin sh run-all.sh`)

Result: OVERALL PASS (rc 0). Shell checks: 104 of 104 PASS, 0 FAIL (proxy entrypoint 28 including SAN cases, injection 6, trust-init 12 on the candidate base and 12 on the live base, trust-jdk 11, core-digest 8, IAM simulation 27 (AWS read-only), Carelog test-proxy.sh). Lint: hadolint (2) PASS, shellcheck PASS, actionlint PASS. Terraform: platform fmt, init, validate PASS, test 23 passed 0 failed; carelog fmt, init, validate PASS, test 10 passed 0 failed.

### 4.7 Not tested here

- ECS injection of the bundle from a real secret (no AWS secret read). Covered by the design and the local env-var and env-file variants.
- Fargate metadata IP (the local stub returns the loopback or a fixed Docker IP).
- A live `terraform plan` against DEV state (not run; section 10).

## 5. Cost (Seoul, ap-northeast-2, DEV, per month)

Assumptions: 1,000 task starts per month (an assumption, not measured). Enrollment Bearer reads are the same in both designs and are excluded.

API calls per task start: 3-secret = 2 (proxy cert and key) + 1 (Core CA) = 3. Single bundle = 1 (proxy) + 0 (Core TLS) = 1.

| Item | Unit price (Seoul, 2026-11-24) | 3-secret | Single bundle |
| --- | --- | --- | --- |
| Secrets Manager secret | $0.40 per secret-month | 3 secrets = $1.20 | 1 secret = $0.40 |
| Secrets Manager API requests | $0.05 per 10,000 requests | 3,000 = $0.015 | 1,000 = $0.005 |
| KMS (AWS managed key) | $0 | $0 | $0 |
| ECR storage, both images | $0.10 per GB-month | about $0.11 | about $0.11 |
| ECR data transfer, same-region pull to ECS | not fetched in this session | assumed $0 | assumed $0 |
| **Monthly total (secrets, API, ECR)** | | **about $1.33** | **about $0.52** |
| Option: CMK (one key) | $1.00 per key-month + $0.03 per 10,000 requests | +$1.00 | +$1.00 |

Difference: about $0.81 per month in favour of the single bundle. Cost is not the deciding factor; the version-skew risk, the boundary and the rollback are.

## 6. Price sources (fetched 2026-11-24)

- `aws pricing get-products` with `regionCode=ap-northeast-2`: AWSSecretsManager (Secret $0.40 per secret-month, usagetype `APN2-AWSSecretsManager-Secrets`; API Request $0.05 per 10,000, `APN2-AWSSecretsManagerAPIRequest`), AmazonECR (`APN2-TimedStorage-ByteHrs` $0.10 per GB-month), AWSKMS (customer managed key $1.00 per key-month, requests $0.03 per 10,000).
- Raw JSON kept under the private scratch directory (not in Git).
- ACM Private CA prices (about $400 per CA-month general purpose, about $50 short-lived) are carried from earlier prep and were not re-verified. Rejected either way.

## 7. Edits for Carelog-owned files

Owned by the Carelog agent or lead; not edited here. `candidates/carelog-tls/platform.tfvars.example` is owned by the platform side and is already updated (no SPRING_PROFILES_ACTIVE, pinned candidate Core input, JAVA_TOOL_OPTIONS merged by Terraform).

### 7.1 `candidates/carelog-tls/task-fragments.json`

Before (proxy `secrets`):
```json
"secrets": [
  { "name": "TLS_CERT_PEM", "valueFrom": "REPLACE_WITH_CERT_SECRET_ARN" },
  { "name": "TLS_KEY_PEM", "valueFrom": "REPLACE_WITH_PRIVATE_KEY_SECRET_ARN" }
]
```
After:
```json
"secrets": [
  { "name": "TLS_BUNDLE_JSON", "valueFrom": "REPLACE_WITH_SERVER_BUNDLE_SECRET_ARN" }
]
```
Before (`coreTaskFragment.initContainer`): the `"secrets"` array with `CARELOG_CA_PEM`. After: delete the `"secrets"` key from `initContainer` (the CA is baked into the image).

### 7.2 `candidates/carelog-tls/carelog.tfvars.example`

Before:
```hcl
  secret_arns = ["REPLACE_WITH_CERT_SECRET_ARN", "REPLACE_WITH_KEY_SECRET_ARN"]
  ...
    secrets = [{ name = "TLS_CERT_PEM", valueFrom = "REPLACE_WITH_CERT_SECRET_ARN" }, { name = "TLS_KEY_PEM", valueFrom = "REPLACE_WITH_KEY_SECRET_ARN" }]
```
After:
```hcl
  secret_arns = ["REPLACE_WITH_SERVER_BUNDLE_SECRET_ARN"]
  ...
    secrets = [{ name = "TLS_BUNDLE_JSON", valueFrom = "REPLACE_WITH_SERVER_BUNDLE_SECRET_ARN" }]
```
The bare ARN (with suffix) has no json-key and no version. Required: one read per container start.

### 7.3 `candidates/carelog-tls/README.md`

Replace references to a CA secret and to the separate cert and key secrets with: "public CA bundle baked into the trust-init image (`CA_BUNDLE_SRC`)" and "one secret `server-bundle`". Lead to decide the wording.

## 8. Conditions that would break the single-bundle design

| Condition | Effect | Alternative |
| --- | --- | --- |
| Security review requires the CA to change without an image rebuild | Baked CA needs a rebuild per change | Core-only CA secret (boundary change), or the 3-secret fallback (section 13) |
| Two leaves must be served at once by different proxies | One bundle holds one pair | One bundle per pair (not a split cert/key) |
| A json-key form is required elsewhere | Version skew returns; version-id pinning needs TD revisions | Section 3.4 |
| The JSON escaping breaks in a tool | Bad PEM | Build the JSON only with `jq --rawfile` (section 11.1) |
| Fargate metadata differs from the stub | Proxy refuses to start (fail-fast) | Test on a real task (not done) |

## 9. Open questions

1. Who owns the offline CA and the signing ceremony? Not defined in the repo.
2. Does security accept a baked CA (rebuild per CA change)?
3. Is a CMK required? If yes, +$1.00 per month and `kms:Decrypt` in both boundaries.
4. The public CA bundle `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem` must be committed by its owner. The draft workflow fails closed without it.
5. Does enrollment need `SPRING_PROFILES_ACTIVE=dev` at all? Section 12 says the enrollment client does not; the registration path does.

## 10. Core image: candidate pin, trust-init base, live reference

| Item | Value | Where it is checked |
| --- | --- | --- |
| Candidate Core container image (enrollment-capable) | `sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf` | `environments/dev/platform/core_env.tf` constant `pinned_candidate_core_image`; `variables.tf` `enrollment_core_candidate` validations (digest form, equal to trust base); `tests/core_env.tftest.hcl` |
| trust-init base (`CORE_IMAGE` build arg, OCI label `ranikun.carelog.core-base`) | must equal the candidate digest | `tests/check-core-digest.sh --tfvars` (reads the platform input) and the workflow (before build and after build) |
| Live Core (TD `:3`, do not touch) | `sha256:ad9f8428...` (118 default CA entries) | negative and "existing live CA" tests only (`run-all.sh`, `CORE_LIVE_IMAGE`) |
| Candidate Core store | 117 default CA entries (`8353cec4`) | counted from the image at test time, not hard-coded |

Verified facts about the two images (local, read-only):
- Both are JDK 21 (`21.0.13.1`, Temurin), `keystore.type` `pkcs12`. The default trust store is PKCS12, so the produced store (a copy of `cacerts` plus the private CA) has the same format as the JVM default.
- Neither image sets `JAVA_TOOL_OPTIONS` or `SPRING_PROFILES_ACTIVE` in its ENV.
- `JAVA_TOOL_OPTIONS` is read by the JVM (`Picked up JAVA_TOOL_OPTIONS` at start). With `-Djavax.net.ssl.trustStore=... -Djavax.net.ssl.trustStorePassword=changeit` and no trustStoreType, the trust store type is the JDK default `pkcs12`.

Terraform plan comparison (offline, mock provider): candidate off gives the live names plus `PLATFORM_CORE_PORT`, and the live image. Candidate on adds the enrollment keys, sets the Core image to `8353cec4`, and sets SPRING and JAVA_TOOL_OPTIONS per section 12. A live `terraform plan` against DEV state was **not run**. The lead should run it and confirm the Core diff is additive and the image change is the pinned candidate.

Repository variable `DEV_CORE_TASK_IMAGE` (optional in the workflow): when set, it must hold the **candidate** Core digest (`8353cec4`), the same value as `enrollment_core_candidate.image`. It is not the live digest. The workflow stops if it differs from the platform input.

## 11. Deployment and recovery (single bundle)

Protected secret: **`ranikun/dev/carelog/enrollment-service-XXXXXX` (enrollment Bearer).** No procedure in this document puts, deletes, rotates, restores, changes a version stage on, or reads it. The rollback operator policy (`candidates/carelog-tls/tests/iam/rollback-operator.json`) has no Allow on it and an explicit Deny (`secretsmanager:*`). Attach that Deny to the operator's permission set or role. An explicit Deny in any policy of the principal overrides an Allow elsewhere. `test-iam-sim.sh` confirms explicitDeny for stage move, put, restore, rotate, delete and read on the enrollment secret.

Placeholders: `<BUNDLE_ARN>` is the full ARN with its 6-character suffix (known after creation). `<CLUSTER>` is the DEV ECS cluster.

### 11.1 Deploy: create, put, reference, force a new deployment

Who: operator with `secretsmanager:CreateSecret` on `ranikun/dev/carelog/enrollment-tls/server-bundle-*` (once) and `secretsmanager:PutSecretValue` on the same name (per renewal). Deployer with `ecs:RegisterTaskDefinition` and `ecs:UpdateService` on the Carelog service.

1. Build the bundle offline from files, compact, never echoed: `jq -c -n --rawfile c leaf.crt --rawfile k leaf.key "{tls_certificate:\$c, tls_private_key:\$k}" > bundle.json`. Before upload: `openssl x509 -in leaf.crt -noout -checkend 0` and `-ext subjectAltName` must list `DNS:ranikun-carelog-dev-api.dev.internal`.
2. Create (first time only): `aws secretsmanager create-secret --name ranikun/dev/carelog/enrollment-tls/server-bundle --secret-string file://bundle.json` (AWS managed key). Then delete `bundle.json`.
3. New version (renewal): `aws secretsmanager put-secret-value --secret-id ranikun/dev/carelog/enrollment-tls/server-bundle --secret-string file://bundle.json`. The previous version becomes `AWSPREVIOUS`. Then delete `bundle.json`.
4. Reference by bare ARN in the candidate input: `secret_arns = ["<BUNDLE_ARN>"]` and `containers[].secrets = [{ name = "TLS_BUNDLE_JSON", valueFrom = "<BUNDLE_ARN>" }]`.
5. Register the reviewed task definition (Terraform through the reviewed plan), then `aws ecs update-service --cluster <CLUSTER> --service ranikun-carelog-dev-api --task-definition <family:revision> --force-new-deployment`.
6. Verify: proxy log `test is successful`; container health check healthy; the served certificate fingerprint equals the new leaf's (section 3.3 step 4); a TLS request from a Core task to port 8443 with the correct name succeeds.

### 11.2 Roll back the certificate

Section 3.3. In short: restore the previous version of the single bundle (`update-secret-version-stage`, AWSCURRENT moved back), force a new deployment, verify the served fingerprint. Key and certificate move together.

### 11.3 Roll back the task definition

Use only when the container or its configuration is at fault. Deployer with `ecs:UpdateService`.

1. Previous Carelog task definition revision (recorded before the change; the no-TLS baseline is revision `:6` in the rollout record, confirm in `carelog-tls-ecs-rollout-rollback.md`). Images are digest-pinned; never roll back by tag.
2. `aws ecs update-service --cluster <CLUSTER> --service ranikun-carelog-dev-api --task-definition ranikun-carelog-dev-api:<previous-revision> --force-new-deployment`.
3. The Core init container is removed by a separate change on `ranikun-platform-dev-core` (its own grant, not in `rollback-operator.json`).

### 11.4 What recovery must never do

- Put, delete, rotate, restore, or change a version stage on `ranikun/dev/carelog/enrollment-service-XXXXXX`.
- Use `secretsmanager:*` on `ranikun/dev/carelog/*` for the operator.
- Delete the bad bundle version during an incident.
- Treat `AWSPREVIOUS` as good without checking the fingerprint.

## 12. Spring profile and JVM options (decisions, with evidence)

Evidence (platform-services commit `dc63569`, read by a shallow fetch into the private scratch directory):
- `platform-core/app/src/main/resources/application.yml` (106 lines) has no `spring.config.activate.on-profile` section and no `application-*.yml` file exists in platform-core. The `dev` profile therefore changes no file-based configuration.
- The only `@Profile` in platform-core is `app/.../LocalTestSharedAiExecutionController.java:38`: `!prod & !production & (local | test)`. It is inactive with or without `dev`. No `@Profile("default")`, no `spring.profiles.default`, and no `application-default` exists, so dropping the implicit `default` profile removes nothing.
- The registration path reads `dev` explicitly: `identity/.../CarelogRegistrationCompositionConfiguration.java:47` (`anyMatch("dev"::equalsIgnoreCase)`), and `requireDevComposition` (lines ~45-58) also requires `platform.identity.carelog-enrollment.enabled=true` and refuses production. `identity/.../adapter/http/CarelogRegistrationHttpConfiguration.java:21` does the same. Both are gated by `platform.identity.carelog-registration.enabled` (lines 25 and 15).
- The enrollment client itself has **no profile condition**: `identity/.../adapter/enrollment/CarelogEnrollmentClientConfiguration.java:15` is `@ConditionalOnProperty(prefix = "platform.identity.carelog-enrollment", name = "enabled", havingValue = "true")`. Env `PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED` binds to it.

Decision:
- **SPRING_PROFILES_ACTIVE**: with enrollment on (merged environment says `true`), `dev` is appended to the existing list. Live empty gives `dev`; `a, b` gives `a,b,dev`; `dev` in any case already present gives no change. Whitespace is trimmed, the comparison is case-insensitive, and a value that is only a substring (`preprod-like`) is not a production profile. Any list element `prod` or `production` (any case) in the live or candidate value fails the plan (key name only). With enrollment off the live value is kept exactly.
- Why append `dev` although enrollment alone does not need it: the registration path in the candidate example (`PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED=true`) requires `dev`, and registration cannot start without enrollment. Keying the rule on enrollment covers both.
- The implicit `default` profile is dropped when `dev` is set. Nothing in platform-core keys on it (see evidence), so no default-profile configuration is lost.

JVM options (tested empirically in the candidate Core image, JDK 21.0.13.1, with `PropPrint` in the private scratch directory):
- The **last** `-D` wins for duplicate options: `-Dx=A -Dx=B` gives `B`; the reverse gives `A`. `trustStorePassword` given twice gives the last one. A duplicate therefore hides a conflict; the rule avoids duplicates.
- Default keystore type `pkcs12` (`Security.getProperty("keystore.type")`), and `trustStoreType` unset: the produced store (copy of the Core `cacerts`, PKCS12) matches the default.

Decision for JAVA_TOOL_OPTIONS with enrollment on:
- Keep every existing option in order; append the missing truststore options `-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts` and `-Djavax.net.ssl.trustStorePassword=changeit`. Options already present exactly are not duplicated.
- An existing `trustStore`, `trustStorePassword` or `trustStoreType` option that differs from the required value **fails the plan** (option keys only in the message). Replacing it silently could drop the Core's existing trust, and a duplicate would be silently overridden by the last value. The lead must resolve such a conflict explicitly.
- `-Djavax.net.ssl.trustStoreType=pkcs12` (or `PKCS12`) is accepted because it equals the default.

Tests: `environments/dev/platform/tests/core_env.tftest.hcl` (23 run blocks in total for platform, including the 2 contract runs): disabled keeps live names, profile and options (also with `a,prod` and a foreign trustStore present); enabled with live empty, `a, b`, `DEV,a`, ` a , dev `; `prod` in live, `a, PRODUCTION `, `prod` from the candidate (expect failure); substring `preprod-like` (accepted); options kept and appended; truststore already present (no duplicate); pkcs12 accepted; other trustStore, other password, JKS type (expect failure); candidate override of a live key (expect failure).

## 13. 3-secret fallback (not recommended; documented for the security review only)

Used only if the single bundle is rejected. Separate secrets: `ranikun/dev/carelog/enrollment-tls/server-cert` (leaf PEM) and `.../server-key` (leaf key PEM), and the CA (`ca-cert`) read by Core, or the CA baked as in section 3.2. The proxy reads `TLS_CERT_PEM` and `TLS_KEY_PEM` (the entrypoint keeps that path and runs the same pair and SAN checks). Certificate rollback in this design is two stage moves, one per secret, on matching versions, followed by a forced deployment; each must be verified by fingerprint (section 3.3 step 4). The version-skew risk exists in this design; it is covered only by the pair check at start. Costs and boundary statements are in section 5 and `prep-iam-boundary.md`.

## 14. CA store difference (live ad9f8428 vs candidate 8353cec4) and Core outbound TLS (2026-11-24)

Method: `keytool -list -v` on the `cacerts` of each Core image (public data; no secret). SHA-256 fingerprints compared as sets. The test is `candidates/carelog-tls/tests/ca-store-diff.sh`, which computes all counts from the images.

Counts (computed): live store 118 entries, candidate store 117 entries. Both PKCS12. JDK: live `21.0.13`, candidate `21.0.13.1` (Temurin 21.0.13.1+2). The trust-init store is a copy of the image's own `cacerts` plus the private CA, so the effect of the image change is exactly the difference below.

**Finding: one certificate exists only in the live store; none exists only in the candidate.** The other 117 certificates have identical SHA-256 fingerprints in both stores.

| Alias | Subject CN | Valid until (UTC) | SHA-256 fingerprint |
| --- | --- | --- | --- |
| `cn_izenpecom,o_izenpe_sa,c_es [jdk]` | Izenpe.com (IZENPE S.A., ES) | 2037-12-13 08:27:25 | `25:30:CC:8E:98:32:15:02:BA:D9:6F:9B:1F:BA:1B:09:9E:2D:29:9E:0F:45:48:BB:91:4F:36:3B:C0:D4:53:1F` |

Cause: not verified against the JDK change log. The difference is between two JDK builds (21.0.13 and 21.0.13.1), so the newer build most likely drops this root. Documented as an expected difference in `tests/ca-expected-differences.txt`. The test passes only while the difference is exactly this list; any other live-only or candidate-only certificate fails it.

Required trust anchors present with identical fingerprints in both stores (`tests/ca-required-anchors.txt`): ISRG Root X1, ISRG Root X2, Amazon Root CA 1, 2, 3 and 4, Starfield Root Certificate Authority - G2. Amazon Root CA 1-4 and Starfield G2 are the roots of the AWS endpoints. Amazon RDS CA roots are in neither store (unchanged).

Core outbound TLS, per connection (evidence: platform-services `dc63569` source, read by a shallow fetch; live task definition `:3` environment and secret NAMES only; a public TLS handshake to the Redis endpoint, without authentication):

| Connection | Evidence | Trust the JVM uses | Status | Result |
| --- | --- | --- | --- | --- |
| Redis (Upstash, TLS) | Lettuce `client.useSsl()` when `redis-tls-enabled` (`identity/.../adapter/redis/IdentityRedisConfiguration.java:36`); live `PLATFORM_IDENTITY_REDIS_TLS_ENABLED=true` | JVM default truststore | live | **Unaffected.** Observed chain: `*.upstash.io` -> Let's Encrypt YE1 -> Root YE -> ISRG Root X2 (cross-sign). The ISRG self-signed anchors are in both stores with the same fingerprints. Izenpe is not in the chain. |
| Postgres RDS (JDBC) | Live URL parameter `sslmode=require` for `PLATFORM_IDENTITY_DATASOURCE_URL` and `..._FLYWAY_DATASOURCE_URL`; no `sslrootcert` or `verify-full` anywhere in the repository | pgjdbc (not the JVM truststore for `require`) | live | **Unaffected** for `require`, which encrypts without certificate verification. From pgjdbc documentation, not re-tested here. A future `verify-full` would need the RDS CA bundle (absent from both stores). |
| Carelog product claims (HTTP, port 8080) | `identity/.../productclaims/CarelogProductClaimsClientConfiguration.java:16` (enabled by `PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED`); live base URL is `http://` | none (no TLS) | live | **Unaffected.** |
| Carelog enrollment (HTTPS 8443, candidate only) | `identity/.../adapter/enrollment/CarelogEnrollmentClientConfiguration.java:15`; private name `ranikun-carelog-dev-api.dev.internal`, private CA | trust-init store: Core cacerts plus the private CA | candidate only | **Unaffected by the Izenpe difference.** The chain is the private CA, which both images' copies include. |
| Kakao OAuth (HTTPS) | `identity/.../oauth/kakao/KakaoOAuthClientConfig.java:15` is conditional on Kakao configuration; no Kakao name in the live task definition | JVM default | not configured | **Unaffected (not configured).** Would need a separate check if configured later. |
| shared-ai (OpenAI) and shared-audit | Disabled by default (`SHARED_AI_*_ENABLED:false`, `SHARED_AUDIT_ENABLED:false` in `application.yml`); no such names in the live task definition | JVM default | not configured | **Unaffected (not configured).** |
| AWS endpoints from the JVM (Secrets Manager, SSM, CloudWatch, S3) | No AWS SDK in the platform-core build files. Secrets are injected by the ECS agent at task start, and logs go through the ECS log driver, both outside the JVM | n/a | not applicable | **Not applicable to the JVM.** Amazon and Starfield roots are identical in both stores. |

Conclusion per connection: **unaffected** for every configured connection (Redis TLS, RDS `require`, product claims HTTP, candidate enrollment), and **not configured** for the optional ones (Kakao, shared-ai, shared-audit). **Affected: none found.** **Unknown: none for the configured set**, with one limit: the Izenpe root is not evidenced in any configured chain, but a host that chains to it was not searched exhaustively. The live Core logs were not read for TLS errors in this task.

Decision: the Izenpe difference is accepted as documented (no configured connection uses it). It is recorded in `tests/ca-expected-differences.txt`. If a configured outbound endpoint ever chains to Izenpe, the test and this section must be updated before the image is used.

## 15. Enrollment all-or-nothing, V3 gate and candidate JAVA_TOOL_OPTIONS (A4, 2026-11-24)

- **Candidate on** = merged env `PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED` or `PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED` is `true`. Off = candidate environment ignored; Core env names, secret names, execution secret count and containers equal the live inputs (test `disabled_inputs_identical_to_live`).
- **Completeness gate (`enrollment_completeness`, all-or-nothing)**: the pinned Core image `8353cec4`; a trust-init container named `carelog-trust-init` with a digest-pinned image; volume `carelog-trust`; app mount at `/run/carelog-trust`, read-only; dependency on `carelog-trust-init` with condition `SUCCESS`; the private truststore options in `JAVA_TOOL_OPTIONS`; `dev` in `SPRING_PROFILES_ACTIVE`; the enrollment Bearer secret reference (`enrollment_secret_arn`, rendered as `PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL` and in the execution secrets); and no TLS server bundle given to Core. Each missing piece fails with its name (key or gate, never a value). Tests: one `expect_failures` run per missing piece, and a pass run.
- **Candidate JAVA_TOOL_OPTIONS rules (live and candidate values)**: a truststore key other than our exact options (`trustStore`, `trustStorePassword`, or a `trustStoreType` other than `pkcs12`/`PKCS12`) fails; the same key twice with different values fails; an option that disables validation fails (name patterns `trustAll`, `insecure`, `nosslverif`, `disablehostname`, `sslcontext=`, `trustmanager`; `-Djavax.net.ssl.trustStore=NONE` fails as a different store). Revocation toggles (`-Dcom.sun.net.ssl.checkRevocation=false`) are allowed and kept, as decided.
- **V3 documentation gate (`core_v3_gate`)**: required when the effective Core image differs from the live image (`core_runtime.image`), independent of the enrollment flag. Requires `core_v3_db_change_approval` with a non-placeholder `reference` and an ISO-8601 `v3_state_checked_at`. It is a documentation gate, not proof of the database state. Procedure: `docs/handoff/carelog-tls-ecs-rollout-rollback.md` section 8.1.
- **Core inputs for review**: output `core_task_inputs` (names and counts only).
- Tests: `environments/dev/platform/tests/core_env.tftest.hcl` (42 runs) and `contract.tftest.hcl` (2 runs): 44 passed, 0 failed.

### 15.1 CA store and Core outbound TLS

Section 14. The test is `candidates/carelog-tls/tests/ca-store-diff.sh`, checks: differences equal the documented list, required anchors present in both, alias differences explained.
