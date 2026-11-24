# Carelog DEV enrollment TLS: certificate, key and CA storage design (3-secret vs 1-secret)

Status: **design and local tests only.** No secret, certificate, key, or CA was created, read, or changed in AWS. Read-only calls only (Price List API, `iam simulate-custom-policy`, `secretsmanager list-secrets` from earlier prep). Nothing was committed. Local tests used throwaway material under the private scratch directory.

Prices were fetched on **2026-11-24** from the AWS Price List API (`aws pricing get-products --region us-east-1` with `regionCode=ap-northeast-2`), not from the pricing pages. Source rows are listed in section 6.

## 0. Decision summary

| Question | 3-secret (current candidate) | 1-secret (proposed, recommended) |
| --- | --- | --- |
| Secrets Manager secrets | 3: `server-cert`, `server-key`, `ca-cert` | 1: `ranikun/dev/carelog/enrollment-tls/server-bundle` (JSON with `tls_certificate` and `tls_private_key`) |
| CA certificate | Secret, read by Core trust-init at task start | **Public PEM baked into the trust-init image** (build input, never a secret) |
| Who reads what | Carelog proxy reads cert + key (2 calls). Core init reads CA (1 call) | Carelog proxy reads bundle (1 call). **Core reads no TLS secret** |
| Core can read server key? | No (boundary denies) | No (boundary denies bundle, which contains the key) |
| Carelog can read CA? | No (boundary denies) | Not applicable (no CA secret exists) |
| Version skew between cert and key | Possible: two `valueFrom` reads can hit different versions during rotation. Mitigated by the fail-fast pair check (tested) and version-id pinning (section 3.2) | **Not possible**: one `GetSecretValue` returns both keys from one version |
| Monthly cost (DEV, assumptions in section 5) | about $1.22 (secrets + API) | about $0.41 (secret + API) |
| CA rotation | Secret change + task restart, no image rebuild | Image rebuild + Core task deployment (two-CA bundle tested) |
| Enrollment Bearer secret | Separate, unchanged (`ranikun/dev/carelog/enrollment-service-XXXXXX`) | Same |
| Verdict | Fallback. Documented, still works (entrypoint keeps the `TLS_CERT_PEM`/`TLS_KEY_PEM` path, tested) | **Recommended**, if the rebuild cost of a CA rotation is acceptable (DEV CA rotates rarely) |

## 1. Certificate authority, certificates and algorithm (both designs)

- **CA** (offline, operator workstation): ECDSA P-256, self-signed, `basicConstraints=critical,CA:TRUE`, `keyUsage=critical,keyCertSign,cRLSign`, validity 2 years, subject `CN=ranikun dev carelog enrollment CA`. The CA private key is never stored in AWS, never in the image, never in Git.
- **Leaf** (proxy): ECDSA P-256, `basicConstraints=CA:FALSE`, `keyUsage=digitalSignature`, `extendedKeyUsage=serverAuth`, validity 180 days. SAN must contain `DNS:ranikun-carelog-dev-api.dev.internal` (the Cloud Map name Core connects to).
- Local tests used ECDSA P-256 for all throwaway certs (earlier notes used RSA). The JDK in the Core image accepted the ECDSA leaf in the test below (section 4.3).

## 2. Recommended layout (1-secret)

| Item | Value |
| --- | --- |
| Secret name | `ranikun/dev/carelog/enrollment-tls/server-bundle` |
| Secret type | SecretString, JSON object, two keys |
| JSON keys | `tls_certificate` (leaf certificate PEM, no key), `tls_private_key` (leaf private key PEM, unencrypted) |
| Container env | `TLS_BUNDLE_JSON` (whole secret string, **bare ARN, no json-key**) |
| Read by | Carelog execution role (proxy container) only |
| Encryption | AWS managed key `aws/secretsmanager` (same as existing `ranikun/dev/*` secrets, no CMK) |
| Size | about 1.5 KB for one ECDSA leaf (limit 64 KB) |

Why one env var with the bare ARN: ECS fetches each `valueFrom` separately. With one env var and no json-key, ECS performs one `GetSecretValue` for the whole secret, so the two PEM values cannot come from different versions. This removes the version-skew problem instead of relying on pinning.

The PEM newlines are stored as `\n` escapes inside the JSON string. Generated and parsed with `jq` in the proxy image (tested in section 4.1): `jq -er '.tls_certificate'` returns the original PEM.

3-secret fallback (documented, still supported by `proxy-entrypoint.sh`): `TLS_CERT_PEM` = `server-cert` ARN, `TLS_KEY_PEM` = `server-key` ARN, and `CARELOG_CA_PEM` = `ca-cert` ARN for the Core init. For that fallback, use the previous trust-init script (git history) or restore the CA-secret read in the init container.

## 3. Operations

### 3.1 Server certificate and key renewal (1-secret)

1. Generate a new leaf key and CSR offline, sign with the offline CA, check `openssl verify` and the SAN.
2. Build the JSON with both keys together (for example `jq -n --rawfile c leaf.crt --rawfile k leaf.key '{tls_certificate:$c, tls_private_key:$k}'`) and run `PutSecretValue` once. Both keys move in one version, so the pair cannot be split.
3. ECS reads `AWSCURRENT` when a container **starts**. Running tasks keep the old pair. Force a new deployment of `ranikun-carelog-dev-api` (no task definition change needed for the same ARN).
4. Gate: the proxy refuses to start on a mismatched pair (section 4.1). Then check the health check and a TLS handshake from a Core task.
5. Old versions stay as `AWSPREVIOUS` until the rollout is verified.

### 3.2 Pinning, if a json-key form is ever used

If the design moves back to two json-key `valueFrom` entries, the ECS docs (secrets-envvar-secrets-manager, fetched 2026-11-24) say the form is `arn:aws:secretsmanager:{region}:{account}:secret:{name}:{json-key}:{version-stage}:{version-id}`. A version-id can be pinned, but a version-stage cannot be combined with it. Both entries must then carry the same `version-id`, `json-key` set to `tls_certificate` and `tls_private_key` respectively, and empty stage. The version-id is in the Terraform-managed task definition, so every rotation needs a new revision. This is the condition that makes the json-key form worse than the bare ARN for this design. Verified in the ECS docs, not tested in AWS.

### 3.3 CA rotation (baked CA)

The CA is `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem` (public, committed by the CA owner), baked by `Dockerfile.trust` as `CA_BUNDLE_SRC`. Rotation:
1. Add the new CA to the bundle (old and new, two certificates). Build and publish the trust-init image (`dev-carelog-tls-images` workflow). Record the new digest.
2. Register a new Core task definition revision with the new init digest, roll Core. Each Core task now trusts both CAs.
3. Re-issue the leaf under the new CA, `PutSecretValue` on the bundle (section 3.1), force a Carelog deployment.
4. After every Carelog task serves the new leaf, rebuild the trust image with the new CA only, register and roll Core again.

Tested (section 4.3): the store grows by exactly the number of CA certificates (1 → 118, 2 → 119 from 117 default entries). A client trusts a leaf from either CA while both are in the store, and rejects a CA2 leaf when only CA1 is present.

Cost: one trust-init image per CA change (the image is about 749 MB, mostly shared base layers, one new small layer). Compared with the 3-secret design, CA rotation adds one Core rollout. Certificates are the expensive part of both designs and are not affected.

Rejected for DEV: a CA secret read by Core (it would give Core a secret read, which is the boundary change this design avoids).

### 3.4 Rollback

- **Leaf (1-secret):** move `AWSCURRENT` back to the previous version (`PreviousVersion` in `describe-secret`) and force a Carelog deployment. Or point the service at the previous Carelog task definition revision (keep the revision that has the previous proxy digest). Both need a write, not done here.
- **Trust-init:** point the Core service back to the previous task definition revision (the one without the init container, or with the previous init digest). Record the digests in `prep-images.md` before each change. Core keeps running with the old store until its tasks are replaced.
- **Carelog:** roll back to the previous task definition revision (`:6` is the live revision named in the task brief; confirm the no-TLS baseline in `carelog-tls-ecs-rollout-rollback.md` before use) through the reviewed rollout path. Do not roll back by tag.
- Images are referenced by digest in every task definition, so rollback never depends on a tag.

## 4. Local tests (throwaway material, Docker Desktop 29.7.2)

All checks are now portable scripts in `candidates/carelog-tls/tests/` (run all with `candidates/carelog-tls/tests/run-all.sh`, which builds the images, generates throwaway CA and leaf material in a temporary directory, runs every check and removes the material). The results below were produced by the earlier private scripts and were re-run by `run-all.sh` on 2026-11-24 (section 12).

### 4.1 Proxy: pair check and single-secret parsing (`proxy-entrypoint.sh`)

The entrypoint accepts `TLS_BUNDLE_JSON` (1-secret) or `TLS_CERT_PEM` + `TLS_KEY_PEM` (3-secret). It then compares `openssl x509 -pubkey` and `openssl pkey -pubout` hashes and exits non-zero on a mismatch. Messages never print values, and the mismatched files are removed.

| Case | Expected | Result |
| --- | --- | --- |
| 1-secret, matching pair in bundle | starts, `nginx -t` ok | PASS |
| 1-secret, cert from one leaf and key from another | refused: "do not match" | PASS |
| 1-secret, bundle without `tls_private_key` | refused | PASS |
| 3-secret, matching pair | starts | PASS |
| 3-secret, cert from version 2 and key from version 1 (rotation skew) | refused: "do not match" | PASS |
| 3-secret, cert with an unrelated key | refused | PASS |
| no TLS input | refused (`:?` message) | PASS |

Command: `tests/test-proxy-entrypoint.sh` -> `RESULT: PASS (all entrypoint pair cases)`. The proxy image now includes `openssl=3.3.7-r2` (pinned in `Dockerfile`; the nginx base does not ship the CLI). In this test, the metadata endpoint is a stub that returns `127.0.0.1`.

### 4.2 Proxy: JSON escaping

The bundle is built with `jq --rawfile` and parsed back with `jq -er`. The PEM round-trips exactly (the nginx start in 4.1 proves the parsed PEM is valid, since `nginx -t` would fail otherwise).

### 4.3 Core trust-init with the CA baked in (`Dockerfile.trust`, `trust-init.sh`)

Base (old, superseded by section 10): `8353cec4...` with 117 default entries. The live Core digest `ad9f8428...` has 118 default entries; all store counts in section 10 use the live digest.

| Case | Expected | Result |
| --- | --- | --- |
| Build without `CA_BUNDLE_SRC` | fails closed (COPY of empty source) | PASS |
| Bundle with 1 CA | store 117 -> 118 (+1), exit 0 | PASS |
| Bundle with 2 CAs | store 117 -> 119 (+2), exit 0 | PASS |
| Bundle containing a leaf (not CA) | refused: "not a CA" | PASS |
| `CARELOG_CA_BUNDLE` path missing | refused | PASS |
| Default aliases preserved | 117 non-`carelog-dev-ca-*` entries remain; 2 `carelog-dev-ca-*` aliases | PASS |
| JDK client (Core image, `JAVA_TOOL_OPTIONS` as in the candidate), 2-CA store, CA1 leaf, by name | HTTP 403 (handshake ok, proxy refused path) | PASS |
| 1-CA store, CA1 leaf, by name | HTTP 403 | PASS |
| 2-CA store, CA1 leaf, by IP (no IP SAN) | handshake fails | PASS |
| default store only (no init), CA1 leaf | handshake fails (PKIX) | PASS |
| 2-CA store, CA2 leaf (rotation overlap), by name | HTTP 403 | PASS |
| 1-CA store (CA1 only), CA2 leaf | handshake fails | PASS |

Command: `tests/test-trust-jdk.sh` -> `RESULT: PASS (trust-init + JDK client)`. The client is `candidates/carelog-tls/TlsProbe.java`, compiled with JDK 21 and run in the Core image.

### 4.4 Lint (2026-11-24)

| Tool | Command | Result |
| --- | --- | --- |
| hadolint | `hadolint/hadolint:latest` on `Dockerfile` and `Dockerfile.trust` | PASS (rc 0) |
| shellcheck | `koalaman/shellcheck:stable -s sh` on `trust-init.sh` and `proxy-entrypoint.sh` | PASS (rc 0) |
| actionlint | `rhysd/actionlint:latest` on `.github/workflows-draft/dev-carelog-tls-images.yml` | PASS (rc 0) |
| bash -n | not repeated; shellcheck parses both scripts | PASS |

### 4.5 Not tested

- ECS injection of `TLS_BUNDLE_JSON` from a real secret (needs AWS read of a real secret, not allowed here). Covered only by the docs statement in 3.2 and by the design.
- Fargate metadata IP lookup (`ECS_CONTAINER_METADATA_URI_V4`). The local stub returns `127.0.0.1`.
- ECDSA chains in the production Core JDK are tested with the throwaway ECDSA CA above; the real CA must go through the same `trust-init` test before first use.

## 5. Cost (Seoul, ap-northeast-2, DEV, per month)

Assumptions: 1,000 task starts per month (ECS deploys, restarts, and replacements, an assumption, not measured). Enrollment Bearer reads are identical in both designs and excluded.

API calls per task start: 3-secret = 2 (proxy cert + key) + 1 (Core CA) = 3. 1-secret = 1 (proxy bundle) + 0 (Core) = 1.

| Item | Unit price (Seoul, 2026-11-24) | 3-secret | 1-secret |
| --- | --- | --- | --- |
| Secrets Manager secret | $0.40 per secret-month | 3 x $0.40 = $1.20 | 1 x $0.40 = $0.40 |
| Secrets Manager API requests | $0.05 per 10,000 requests | 3,000 requests = $0.015 | 1,000 requests = $0.005 |
| KMS (AWS managed key `aws/secretsmanager`) | $0 | $0 | $0 |
| ECR storage, both images | $0.10 per GB-month | about $0.11 (proxy 75 MB + trust-init 749 MB, both designs) | same (about $0.11) |
| ECR data transfer, same-region pull to ECS | not fetched in this session | assumed $0 | assumed $0 |
| **Monthly total (secrets + API + ECR)** | | **about $1.33** | **about $0.52** |
| Option: customer managed KMS key (one per design) | $1.00 per key-month + $0.03 per 10,000 requests | +$1.00 | +$1.00 (same) |

Difference: about **$0.81 per month** in favor of 1-secret. Cost is not the deciding factor. The deciding factors are the boundary (section 6 of `prep-iam-boundary.md`) and the version-skew risk.

Not re-verified in this session (carried from earlier prep): ACM Private CA general purpose about $400 per CA-month and short-lived mode about $50 per CA-month. Rejected, unchanged.

## 6. Price sources (fetched 2026-11-24)

- `aws pricing get-products --service-code AWSSecretsManager` with `regionCode=ap-northeast-2`: Secret $0.40 per secret-month (usagetype `APN2-AWSSecretsManager-Secrets`), API Request $0.05 per 10,000 requests (`APN2-AWSSecretsManagerAPIRequest`).
- `--service-code AmazonECR`: `APN2-TimedStorage-ByteHrs` $0.10 per GB-month.
- `--service-code AWSKMS`: customer managed key $1.00 per key version-month (`ap-northeast-2-KMS-Keys`), requests $0.03 per 10,000 (`ap-northeast-2-KMS-Requests`).
- Raw JSON: `private/prep2-platform/pricing-*.json` (not in Git).

## 7. Edits for Carelog-owned files

These files are owned by the Carelog agent or lead. I did not edit them. Apply the exact before/after below. Each edit is needed for the single-bundle design and for the Core preservation rule in section 10.

### 7.1 `candidates/carelog-tls/task-fragments.json`

Before (proxy secrets):
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
Before (`coreTaskFragment.initContainer`): the `"secrets"` array with `CARELOG_CA_PEM`.
After: delete the `"secrets"` key from `initContainer`. The CA is baked into the image.

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
The bare ARN (with suffix) has no json-key and no version. This is required: it keeps one read per container start.

### 7.3 `candidates/carelog-tls/platform.tfvars.example` (not in the owned list; for the lead)

Before:
```hcl
  environment = {
    ...
    SPRING_PROFILES_ACTIVE = "dev"
    ...
  }
  secret_arns = ["REPLACE_WITH_CA_SECRET_ARN"]
  ...
    secrets = [{ name = "CARELOG_CA_PEM", valueFrom = "REPLACE_WITH_CA_SECRET_ARN" }]
```
After:
```hcl
  environment = {
    ...
    # SPRING_PROFILES_ACTIVE removed: live Core does not set it, and the Terraform guard in
    # environments/dev/platform/core_env.tf rejects adding it. Add it only if the live task definition sets it.
    ...
  }
  secret_arns = []
  ...
    # no secrets: the CA is baked into the trust-init image (CA_BUNDLE_SRC)
```
Keep `JAVA_TOOL_OPTIONS` as it is. The Terraform merge appends the truststore options to any live value (section 10).

### 7.4 `candidates/carelog-tls/README.md`

Replace the references to the CA secret and to the 3 secrets with: "public CA bundle baked into the trust-init image (`CA_BUNDLE_SRC`)" and "one secret `server-bundle`". Lead to decide wording.

## 8. Conditions that would break the 1-secret design

| Condition | Effect | Alternative |
| --- | --- | --- |
| The security review requires the CA private key or the CA certificate to change without an image rebuild | Baked CA needs a rebuild per change | Keep the 3-secret design, or add a Core-only CA secret (boundary change) |
| Two leaves must be served at the same time (for example by a second proxy) with different keys | One bundle holds one pair | Use a second bundle secret (one per pair), not a split cert/key |
| A json-key form is required by the rest of the platform | Version-skew comes back and version-id pinning needs TD revisions | 3.2 |
| Secret size grows past a few KB (CA chain in the bundle) | Still far below 64 KB | None needed |
| The JSON key escaping breaks in a tool (for example CLI put with shell quoting) | Bad PEM | Write the JSON with `jq` from `--rawfile` (section 3.1), never by hand |
| Fargate metadata differs from the stub | Proxy refuses to start (fail-fast, IP check) | Test on a real task, as already listed in `prep-images.md` |

## 9. Open questions

1. Who owns the offline CA and the signing ceremony? Not defined in the repo.
2. Does the security review accept a baked CA (rebuild per CA change), or require the CA as a secret?
3. Is a CMK required? If yes, both designs cost +$1.00 per month and the boundary needs `kms:Decrypt` (see `prep-iam-boundary.md`).
4. The real CA certificate must be committed as `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem` by its owner before the workflow can run. The draft workflow now fails closed when it is missing.
5. The Carelog-owned edits in section 7 need the Carelog agent or lead.

## 10. Core preservation and trust-init image match (2026-11-24, read-only)

Live Core task definition `ranikun-platform-dev-core:3` (describe-task-definition; env and secret NAMES only, no values):
- Image: `ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001`. This is **not** the digest the earlier prep used (`8353cec4...`, 117 default CA entries). The live digest has **118** default CA entries.
- Environment names (12, plus `PLATFORM_CORE_PORT` added by the module): `PLATFORM_IDENTITY_REDIS_HOST`, `..._REDIS_TLS_ENABLED`, `..._REDIS_PORT`, `..._REDIS_KEY_PREFIX`, `..._PRODUCT_CLAIMS_BASE_URL`, `..._PRODUCT_CLAIMS_ENABLED`, `..._AUTH_ENABLED`, `..._FLYWAY_DATASOURCE_URL`, `..._DATASOURCE_URL`, `..._JWT_ACCESS_TOKEN_VALIDITY`, `..._JWT_REFRESH_TOKEN_VALIDITY`, `PLATFORM_ENVIRONMENT`.
- Secret names (7): datasource and flyway credentials (db-admin), JWT key, Redis password, product-claims secret.
- **Live does not set `JAVA_TOOL_OPTIONS` or `SPRING_PROFILES_ACTIVE`.** The live Core image does not bake them either (its ENV names: PATH, JAVA_HOME, LANG, LANGUAGE, LC_ALL, JAVA_VERSION).
- The live container has a health check (readiness on 9092). The candidate does not change it.

| # | Finding | Fix in this prep | Proof |
| --- | --- | --- | --- |
| 1 | `platform.tfvars.example` sets `SPRING_PROFILES_ACTIVE = "dev"`. Live Core does not set it, so the candidate would add an active profile. | Terraform guard `environments/dev/platform/core_env.tf`: the candidate may not add `SPRING_PROFILES_ACTIVE` unless live sets it. Edit 7.3 removes the line (Carelog-owned example). | `core_env.tftest.hcl` `adding_spring_profile_fails` (expect_failures) |
| 2 | A candidate value that differs from a live key would override it. `JAVA_TOOL_OPTIONS` could replace live options. | `core_env.tf` merges `JAVA_TOOL_OPTIONS` (live options first, then the truststore options). Every other live key is kept. A different candidate value for a live key fails the plan (key names only in the message). | `candidate_keeps_live_parts_and_appends_truststore`, `candidate_without_live_jto_sets_truststore_only`, `override_of_live_key_fails` |
| 3 | The old `merge(core_runtime.environment, ..., candidate.environment)` let the candidate override silently. | Replaced by `local.core_environment` in `services.tf`. | `candidate_disabled_names_equal_live_plus_port` (names = live names + `PLATFORM_CORE_PORT`) |
| 4 | trust-init must start from the Core image's own store and only add the CA. | Design unchanged, now tested against the live digest: base store 118 -> 119 (1 CA) and 118 -> 120 (2 CAs). All 118 base aliases are still present. | `test-trust-init.sh` (12 checks) |
| 5 | The trust-init base must equal the Core task definition digest. Nothing checked it. | `Dockerfile.trust` records `ranikun.carelog.core-base` (label from the `CORE_IMAGE` build arg). `tests/check-core-digest.sh` checks the label and the layer prefix against the expected digest. The workflow compares `core_image` with repository variable `DEV_CORE_TASK_IMAGE` before building, and runs the check after the build. | `test-core-digest.sh`: live PASS; label mismatch, older base, forged label (layers catch it) and non-digest reference all FAIL as required |

Repository variable `DEV_CORE_TASK_IMAGE` must be set to the Core task definition image (the `core_runtime.image` value of the reviewed platform input). The lead sets it. Without it the workflow stops.

Offline plan comparison (mock provider, no DEV state read): with the candidate disabled, Core env names equal the live names plus `PLATFORM_CORE_PORT`. With the candidate enabled and no live `JAVA_TOOL_OPTIONS`, the only additions are the enrollment keys (`PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED`, `..._BASE_URL`) and `JAVA_TOOL_OPTIONS` (truststore options only). A live `terraform plan` against DEV state was **not run**. The lead should run it with the TLS inputs and confirm that the Core diff is additive.

## 11. Deployment and recovery procedure (single bundle)

Protected secret: **`ranikun/dev/carelog/enrollment-service-XXXXXX` (enrollment Bearer). The procedures below never put, delete, rotate, restore, change version stages on, or read it.** The rollback operator policy (`candidates/carelog-tls/tests/iam/rollback-operator.json`) has no Allow on it and an explicit Deny (`secretsmanager:*`). Attach that Deny to the operator's permission set or role. An explicit Deny in any policy of the principal overrides an Allow elsewhere. `test-iam-sim.sh` confirms explicitDeny for stage move, put, restore, rotate, delete and read on the enrollment secret.

Placeholders: `<BUNDLE_ARN>` is the full ARN with its 6-character suffix (known only after creation). `<CLUSTER>` is the DEV ECS cluster.

### 11.1 Deploy: create, put, reference, force a new deployment

Who: operator with `secretsmanager:CreateSecret` on `ranikun/dev/carelog/enrollment-tls/server-bundle-*` (once) and `secretsmanager:PutSecretValue` on the same name (per renewal). Deployer with `ecs:RegisterTaskDefinition` and `ecs:UpdateService` on the Carelog service. Creating or putting needs no read permission.

1. Build the bundle offline from files, compact, never echoed. Keys: `tls_certificate` (one leaf PEM) and `tls_private_key` (PEM). Command: `jq -c -n --rawfile c leaf.crt --rawfile k leaf.key "{tls_certificate:\$c, tls_private_key:\$k}" > bundle.json`. Before upload check the expiry (`openssl x509 -in leaf.crt -noout -checkend 0`) and the name (`-ext subjectAltName` must list `DNS:ranikun-carelog-dev-api.dev.internal`).
2. Create (first time only): `aws secretsmanager create-secret --name ranikun/dev/carelog/enrollment-tls/server-bundle --secret-string file://bundle.json` (AWS managed key, no CMK, like the other `ranikun/dev/*` secrets). Then delete `bundle.json`.
3. New version (renewal): `aws secretsmanager put-secret-value --secret-id ranikun/dev/carelog/enrollment-tls/server-bundle --secret-string file://bundle.json`. The previous version becomes `AWSPREVIOUS`. Then delete `bundle.json`.
4. Reference by bare ARN in the Terraform candidate input: `secret_arns = ["<BUNDLE_ARN>"]` and `containers[].secrets = [{ name = "TLS_BUNDLE_JSON", valueFrom = "<BUNDLE_ARN>" }]`. No json-key and no version-id. ECS reads `AWSCURRENT` when a container starts, in one read, so both keys always come from the same version.
5. Register the reviewed task definition revision (`terraform apply` in `environments/dev/carelog` through the reviewed plan), then force a new deployment: `aws ecs update-service --cluster <CLUSTER> --service ranikun-carelog-dev-api --task-definition <family:revision> --force-new-deployment`. Running tasks keep the old pair until they are replaced.
6. Verify: the proxy log shows `test is successful` and no entrypoint failure line; the container health check is healthy; a TLS request from a Core task to port 8443 with the correct name succeeds.

### 11.2 Recover the previous Secret version (documented, not run)

Who: rollback operator with `secretsmanager:DescribeSecret`, `secretsmanager:ListSecretVersionIds` and `secretsmanager:UpdateSecretVersionStage` on `<BUNDLE_ARN>` only (`tests/iam/rollback-operator.json`).

1. Find the versions: `aws secretsmanager describe-secret --secret-id <BUNDLE_ARN> --query VersionIdsToStages`. Record the version id with `AWSCURRENT` and the one with `AWSPREVIOUS`.
2. Move the stage back: `aws secretsmanager update-secret-version-stage --secret-id <BUNDLE_ARN> --version-stage AWSCURRENT --move-to-version-id <previous-version-id> --remove-from-version-id <current-version-id>`. The bad version keeps its id and is not deleted (kept for the review).
3. Force a new deployment of `ranikun-carelog-dev-api` so that new tasks read the previous version. Verify as in 11.1 step 6.
4. Both keys live in one version, so the rollback is atomic: the previous version is a matched pair. Key-only or cert-only rollback is not possible and not needed.

### 11.3 Roll back the task definition (previous revision, digest-pinned)

Who: deployer with `ecs:UpdateService` on the Carelog service (in `rollback-operator.json`).

1. Use the previous Carelog task definition revision recorded before the change. The no-TLS baseline is revision `:6` in the rollout record; confirm it in `carelog-tls-ecs-rollout-rollback.md` before use. Images are digest-pinned; do not roll back by tag.
2. `aws ecs update-service --cluster <CLUSTER> --service ranikun-carelog-dev-api --task-definition ranikun-carelog-dev-api:<previous-revision> --force-new-deployment`.
3. Removing the Core init container is a separate change on `ranikun-platform-dev-core`. Its rollback needs its own grant (not in `rollback-operator.json`). Its previous revision is the one without the trust-init container.

### 11.4 What recovery must never do

- Put, delete, rotate, restore, or change a version stage on `ranikun/dev/carelog/enrollment-service-XXXXXX`.
- Use `secretsmanager:*` on `ranikun/dev/carelog/*` for the operator.
- Delete the bad bundle version during an incident.
- Assume that `AWSPREVIOUS` is a good version without checking it against the incident record.
