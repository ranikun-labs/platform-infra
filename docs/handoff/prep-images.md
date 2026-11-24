# Carelog DEV TLS candidate: image build and publish prep

Status: **prep only.** Nothing was pushed to ECR, no repository was created, and no task definition was registered. Images were built and tested locally. The draft publish workflow is not active.

Scope: the TLS proxy sidecar (`candidates/carelog-tls/Dockerfile`) and the Core trust-init image (`candidates/carelog-tls/Dockerfile.trust`, built FROM the Core image by digest).

## 1. Pinned inputs

| Input | Value | How obtained |
| --- | --- | --- |
| Proxy base | `nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10` (nginx 1.27.5, Alpine 3.21) | `docker pull nginx:1.27-alpine` from Docker Hub, `RepoDigests` |
| jq (apk) | `1.8.2-r0` | `apk policy jq` in the pinned base |
| Trust-init base (Core) | `124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf` | Digest recorded in the TLS handoff. Image was already local, so no ECR login was needed |
| Core JDK | `jdk-21.0.13.1+2`, PKCS12 `cacerts`, 117 entries, Core has no `USER` (runs as root) | `docker image inspect`, `keytool -list` |

## 2. Changes made to the candidate files (owned by this prep)

| File | Change | Reason |
| --- | --- | --- |
| `Dockerfile` | Base changed from tag `nginx:1.27-alpine` to digest. `jq` pinned to `1.8.2-r0`. Creates `/run/carelog-tls` mode 700 | Reproducible base; hadolint DL3018; the entrypoint failed without the directory |
| `Dockerfile` | `HEALTHCHECK` added (`kill -0 $(cat /run/nginx.pid)`). `pgrep` was tried first and reported unhealthy | Local `docker` health only. **ECS ignores Dockerfile HEALTHCHECK.** The task definition needs an equivalent container `healthCheck` |
| `Dockerfile` | `LABEL org.opencontainers.image.revision=$SOURCE_SHA` | Source SHA provenance |
| `Dockerfile.trust` | Same LABEL. Added hadolint ignore for DL3002/DL3066 with rationale (root is needed to write the task volume) | hadolint |
| `proxy-entrypoint.sh` | Fails fast if `TLS_CERT_PEM` or `TLS_KEY_PEM` is empty (values are never printed). `wget -T 5`. Private key `chmod 600`. `shellcheck disable=SC2016` on the intentional `envsubst` list | Missing secret used to produce a half-written config. Timeout on metadata call |
| `trust-init.sh` | Fails fast on missing `JAVA_HOME` or `CARELOG_CA_PEM`. Final `cacerts` `chmod 644` (it was 600 from `umask 077`). After import, `keytool -list -alias carelog-dev-ca` must succeed | Public CA data only. Core reads it from a read-only mount. The 600 mode would break a non-root Core. The alias check fails the init container if import silently did nothing |

Not changed: `nginx.conf`, `test-proxy.sh`, `EnrollmentProbe.java`, `TlsProbe.java`, Terraform, the two lead-owned docs, and `task-fragments.json` / tfvars examples.

## 3. Local validation (2026-11-24, Docker Desktop 29.7.2, no AWS writes)

| Check | Command (summary) | Result |
| --- | --- | --- |
| Shell syntax | `bash -n trust-init.sh proxy-entrypoint.sh` | PASS |
| shellcheck | `koalaman/shellcheck:stable -s sh` on both scripts | PASS (after the SC2016 disable) |
| hadolint | `hadolint/hadolint:latest` on both Dockerfiles | PASS (rc 0; DL3002/DL3066 ignored deliberately in `Dockerfile.trust`) |
| actionlint | `rhysd/actionlint:latest` on the draft workflow | PASS |
| Build proxy | `docker build -f candidates/carelog-tls/Dockerfile` | PASS. 75.2 MB. Local ID `bb4612b0477a` (tag `carelog-tls-proxy:prep`, not pushed) |
| Build trust-init | `docker build -f Dockerfile.trust --build-arg CORE_IMAGE=<core>@sha256:8353...` | PASS. 749 MB, same size as Core. Only warning is `InvalidDefaultArgInFrom`, which is intended: no default, so a build without a digest fails |
| No baked secrets | `docker history --no-trunc` on proxy image, grep `pem|password|secret` | 0 matches |
| Proxy e2e (throwaway) | See section 4 | PASS |
| Trust-init e2e (throwaway) | See section 4 | PASS |

## 4. Local end-to-end test (throwaway material only)

Material: a throwaway CA and a leaf certificate for `carelog.test` and `10.250.0.10`, generated with OpenSSL under the private scratch directory. A wrong CA was also generated. Nothing was written to the repo. The Docker network `carelog-prep-net` (10.250.0.0/24) and volume `prep-trust` are test-only and can be removed.

Proxy results (client = `nginx:1.27-alpine` with curl, same Docker network, `--cacert` verification):

| Case | Expected | Result |
| --- | --- | --- |
| 8443 PUT enrollment path, correct CA and name | Reaches the backend stub (stub returns 405 for PUT on static files) | PASS (405) |
| 8443 GET enrollment path | Refused by method limit | PASS (403) |
| 8443 other path (`/api/v1/users/customers`) | Refused | PASS (403) |
| 8443 dot-segment and encoded traversal toward a customers path | Refused | PASS (403) |
| 8443 wrong CA | TLS verification fails | PASS (curl exit 60) |
| 8443 wrong host name | TLS verification fails | PASS (curl exit 60) |
| 8080 `/api/v1/users/customers`, 8080 enrollment path, dot-segment / encoded / prefix-confusion bypass variants | Customers reach stub, others refused | PASS (404, then 403 for the rest) |
| Container health (Dockerfile HEALTHCHECK) | healthy | PASS after the `kill -0` change (`pgrep` version was unhealthy) |
| Entrypoint without `TLS_CERT_PEM` or without metadata | Exit non-zero | PASS (`:?` checks) |

Trust-init results:

| Case | Result |
| --- | --- |
| Run with throwaway CA in `CARELOG_CA_PEM`, volume mounted | PASS, exit 0. Store has 118 entries (117 default + `carelog-dev-ca`) |
| Run without `CARELOG_CA_PEM` | PASS (fails, exit 2) |
| JDK client (`java.net.http`) inside the Core image, using the init store via `JAVA_TOOL_OPTIONS` as in the candidate: correct name | PASS (HTTP 405 through the proxy) |
| Same client, wrong name | PASS (fails: `SSLHandshakeException`, hostname) |
| Same client, Core default store only | PASS (fails: PKIX path, so the test CA is not trusted without init) |

The JDK client was compiled in `eclipse-temurin:21-jdk` because the Core image has no `javac`. Its `.class` ran in the Core image.

## 5. ECR repositories the Terraform expects

Existing repositories in account 124495093425 (ap-northeast-2): `ranikun/platform/core`, `ranikun/platform/gateway`, `ranikun/carelog/api`, `ranikun/finance/api`. All are `IMMUTABLE`, scan on push is on, and encryption is `AES256`. The new repositories should match that.

| Repository | Consumer | Terraform input | Expected ARN |
| --- | --- | --- | --- |
| `ranikun/carelog/tls-proxy` | Carelog task, execution role | `environments/dev/carelog`: `enrollment_tls_candidate.ecr_repository_arns = ["<arn>"]`, `containers[0].image = "<repo>@sha256:<digest>"` | `arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy` |
| `ranikun/platform/core-trust-init` | Platform Core task, execution role (init container) | `environments/dev/platform`: `enrollment_tls_candidate.ecr_repository_arns`, `containers[0].image` | `arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init` |

Image references must be digests (`repo@sha256:...`) in task definitions. Tags are for humans only.

**Missing (needs AWS write, not done):** the two repositories do not exist yet. Their digests do not exist yet (no push). The repository ARNs are therefore inferred from the naming convention, not from a live resource.

## 6. Draft publish workflow

File: `.github/workflows-draft/dev-carelog-tls-images.yml` (not under `.github/workflows/`, so it cannot run).

Behavior:
- `workflow_dispatch` with a required Core digest input. The input is validated against the Core ECR repository digest format.
- OIDC through `aws-actions/configure-aws-credentials` (same SHA pin as `dev-ecs-release.yml`). No static keys.
- Builds the proxy from `Dockerfile` and trust-init from `Dockerfile.trust` with `--provenance=false --sbom=false` so the digest is a single image manifest.
- Tags each image `git-<full SHA>` (immutable repo, one tag per commit). Reads the digest from `RepoDigests` after push, cross-checks it with `aws ecr describe-images`, and writes source SHA -> digest to `$GITHUB_STEP_SUMMARY`.
- Reports ECR scan status (non-blocking, same as the existing release).

Required GitHub configuration (not created):
- Environment `dev-carelog-tls-publish`, with required reviewers.
- Environment variables: `AWS_REGION=ap-northeast-2`, `DEV_ECR_REGISTRY=124495093425.dkr.ecr.ap-northeast-2.amazonaws.com`, `DEV_TLS_IMAGE_PUBLISHER_ROLE_ARN=<role below>`.

Before moving it to `.github/workflows/`: check that the action SHA pins are still the ones the owner approved, and confirm the trust `sub` matches the real repository (`ranikun-labs/platform-infra`).

## 7. AWS resources the real workflow needs (documentation only)

**a. ECR repositories** (create once, `ecr:CreateRepository`): `ranikun/carelog/tls-proxy` and `ranikun/platform/core-trust-init`. Settings: `IMMUTABLE`, `scanOnPush=true`, `AES256`. Add a lifecycle policy that keeps the last 10 images. Expected cost is in `prep-aws-changes.md`.

**b. OIDC publish role** `ranikun-dev-carelog-tls-image-publish` (new, not the existing `DEV_PUBLISHER_ROLE_ARN`, to keep scope narrow).
- Trust: `Federated: arn:aws:iam::124495093425:oidc-provider/token.actions.githubusercontent.com`. Conditions: `token.actions.githubusercontent.com:aud = sts.amazonaws.com` and `token.actions.githubusercontent.com:sub = repo:ranikun-labs/platform-infra:environment:dev-carelog-tls-publish`. The provider already exists in the account (checked read-only).
- Permissions:
  - `ecr:GetAuthorizationToken` on `*`.
  - On both new repositories: `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`, `ecr:DescribeImages`, `ecr:DescribeImageScanFindings`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`.
  - On `ranikun/platform/core` only (read, needed for `docker build --build-arg CORE_IMAGE`): `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability`.
  - No Secrets Manager, KMS, IAM, or ECS permissions.
- Optional: a permission boundary, if the account's convention requires one.

**c. GitHub environment and variables**: see section 6.

**d. Not needed for images:** Secrets Manager and boundary changes are in `prep-cert-secrets.md` and `prep-iam-boundary.md`.

## 8. Open questions

1. The proxy master process runs as root (needed to write the task volume and to bind). Workers run as `nginx`. Acceptable for DEV? Alternative is a pre-created volume owned by a non-root UID, which needs a task-definition `user` and an ECS volume-ownership check.
2. The Core base image runs as root by default. This is pre-existing and not changed here.
3. CA rotation: **resolved in section 9** (multi-CA bundle import tested; the CA is baked into the image, so rotation is an image rebuild plus Core rollout). Section 2 and section 4 describe the earlier single-CA state (`CARELOG_CA_PEM`), which is superseded.
4. The server certificate SAN must include the Cloud Map name the Core uses: `ranikun-carelog-dev-api.dev.internal` (taken from `platform.tfvars.example`). The local test used `carelog.test`.
5. The Dockerfile HEALTHCHECK is local only. The task definition needs an explicit container `healthCheck` (for example `CMD-SHELL kill -0 $(cat /run/nginx.pid)`), to be reviewed with the task fragment.
6. Fargate sizing of the sidecar: see `prep-aws-changes.md`.
7. The `ECS_CONTAINER_METADATA_URI_V4/task` lookup takes the first IPv4 across all containers. With `awsvpc`, all containers share the task IP, so this is correct. It was not tested on Fargate.

## 9. Update 2026-11-24: 1-secret design, CA baked into trust-init (tested)

| File | Change | Reason |
| --- | --- | --- |
| `Dockerfile` | `apk add jq=1.8.2-r0 openssl=3.3.7-r2` (openssl pinned, the nginx base has no CLI) | Fail-fast certificate/key pair check in the entrypoint |
| `proxy-entrypoint.sh` | Accepts `TLS_BUNDLE_JSON` (keys `tls_certificate`, `tls_private_key`, one secret) or the 3-secret `TLS_CERT_PEM`/`TLS_KEY_PEM`. Compares SPKI hashes of cert and key; mismatch removes the files and exits 1 without printing values. The bundle variable is unset after parsing | Version-skew safety and the 1-secret design |
| `Dockerfile.trust` | `ARG CA_BUNDLE_SRC` (no default, so a build without it fails). `COPY` the public PEM bundle to `/usr/local/share/carelog/carelog-dev-ca-bundle.pem`. Bundle is a build input, never a secret | CA baked in; public material |
| `trust-init.sh` | Reads the baked bundle (`CARELOG_CA_BUNDLE` overrides the path for tests). Splits the bundle, imports each certificate under its own alias, refuses non-CA certificates (`CA:TRUE` check), and requires the store to grow by exactly the number of certificates. No secret env var | Multi-CA bundle (rotation overlap) and no CA secret |
| `.github/workflows-draft/dev-carelog-tls-images.yml` | New step checks that `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem` exists, contains a certificate, and has no private key. Trust build passes `CA_BUNDLE_SRC=ca/carelog-dev-ca-bundle.pem` | CA as build input. The step fails closed until the public CA is committed |

Tests run (2026-11-24, throwaway material, Docker Desktop 29.7.2):

| Test | Command | Result |
| --- | --- | --- |
| Entrypoint pair check, 7 cases (1-secret match/mismatch/no key, 3-secret match/skew/unrelated key, no input) | `bash private/prep2-platform/test-entrypoint-pair.sh` | PASS (7 of 7) |
| trust-init store growth and JDK client, 1-CA and 2-CA bundles, CA1 and CA2 leaves, wrong name, default-only store | `bash private/prep2-platform/test-jdk-trust.sh` | PASS (7 of 7) |
| Leaf-only bundle refused; build without `CA_BUNDLE_SRC` fails | `docker build` / `trust-init` runs | PASS |
| hadolint (`Dockerfile`, `Dockerfile.trust` with the documented ignores) | `hadolint/hadolint:latest` | PASS (rc 0) |
| shellcheck (`trust-init.sh`, `proxy-entrypoint.sh`, `-s sh`) | `koalaman/shellcheck:stable` | PASS (rc 0) |
| actionlint (draft workflow) | `rhysd/actionlint:latest` | PASS (rc 0) |

Store numbers: default store 117 entries; 1 CA -> 118; 2 CAs -> 119; 2 `carelog-dev-ca-*` aliases; 117 default aliases preserved.

Not run: `terraform fmt/validate/test` (no Terraform file in `environments/dev/platform` was changed). No image was pushed; the local tags `carelog-tls-proxy:prep2` and `carelog-trust-prep2:{1,2,leaf,nocert}` are local only.
