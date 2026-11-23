# Local candidate validation

Do not apply candidate.tf standalone. Integrate its statement with each Terraform-managed execution policy and allow certificate, key, CA secret and image ECR access after resources are identified. `task-fragments.json` is not a complete ECS task definition. Merge into actual definitions while preserving existing containers, environment, secrets, and health checks. Replace all placeholders with non-secret identifiers and digest pinned private images. Configure init container command /usr/local/bin/trust-init and SUCCESS dependency. The init image should be built from Dockerfile.trust. JAVA_TOOL_OPTIONS uses the JDK default truststore integrity password, not a private credential. Confirm actual JDK store type and the image baseline before use.

1. Build proxy and init images locally. Verify `nginx -t` using a temporary test-only keypair and matching SAN, with no production material.
2. Launch a test-only HTTP server on the same Docker network namespace as proxy. Send HTTPS with CA verification and matching hostname; verify proxy delivers the original request. Test wrong CA and hostname fail.
3. Run init container with test CA and a mounted volume. Confirm Java default store certificates remain, test CA is present, then run JDK client with that store to verify correct and incorrect hostname behavior.
4. Check planned task environment and `dependsOn`, IAM simulation, secret-reference uniqueness and SG 8443. Run `terraform validate` and inspect plan against real managed state before apply. Verify health checks and private-key permissions.

No production TLS credentials, certificate, CA or new AWS resources have been created. CA lifecycle, sidecar resource size, image provenance, rotation and costs remain open. AWS Private CA pricing https://aws.amazon.com/private-ca/pricing/ lists $400 per month general-purpose or $50 short-lived mode, plus issuance. Secrets Manager https://aws.amazon.com/secrets-manager/pricing/ charges per secret and API call. Verify Seoul regional prices. Alternative self-managed CA has operational costs and requires safe key custody and rotation.

Security status: the proxy currently denies every request on external port 8080 until the full required Gateway and Core claims path allowlist is verified. It is intentionally unusable for deployment. The existing Gateway route /api/** is too broad to establish a safe endpoint allowlist. A path enumeration and normalized/encoded URI bypass tests are mandatory. Carelog must be bound to 127.0.0.1:8080 and proxy must bind the task IP. ECS task metadata IP selection must be validated in Fargate. Never apply this candidate to the running service as-is.

Current candidate routing supersedes the earlier deny-all paragraph: 8080 permits `/api/v1/users/customers`, `/api/v1/customer-events`, and `/api/v1/internal/identity/claims` with segment boundaries, and rejects other paths. 8443 permits only the single-account enrollment path. The allowlist derives from e1f994c2 controller source and is incomplete for other existing APIs. It is not approved for deployment. Normalization, encoded-path and integration tests remain mandatory.

External review request: review this commit and the Carelog #61 e1f994c2 integration for 8080 bypass, Spring/nginx URL normalization, API compatibility, Fargate metadata address discovery, same-task bind behavior, IAM least privilege, digest pinning, task startup dependencies, truststore parity, certificate rotation and Terraform plan. Report APPROVE or findings and exact reviewed SHA. Do not apply or merge.

## Reproduction and observed result

On 2026-11-23 the following local-only stub test passed. It generates a disposable CA and keypair inside the container. No real credentials are read.

```powershell
docker build -t carelog-dev-tls-candidate:local candidates/carelog-tls
$testScript = (Resolve-Path candidates/carelog-tls/test-proxy.sh).Path
docker run --rm --entrypoint sh -v "${testScript}:/tmp/test-proxy.sh:ro" carelog-dev-tls-candidate:local /tmp/test-proxy.sh
```

Customers, customer-events and claims reached the static backend stub (404), enrollment requests to 8080 and selected normalized/encoded bypass variants returned 403, and an enrollment request to 8443 reached the stub over TLS (404). Incorrect CA and wrong hostname failed TLS verification. This does not execute the Carelog API, the JDK client, ECS networking, an exhaustive path-bypass suite, or the certificate delivery and rotation mechanism. The test downloads apk packages and uses a local Docker runtime.

## Real DEV plan prerequisites

Use the existing protected DEV `terraform.tfvars` values, state backend bucket and AWS profile. Do not print tfvars or state because they may contain sensitive material. The repository operator workflow documents required inputs. Run backend initialization against the existing correct state before a read-only plan, for each of `environments/dev/platform` and `environments/dev/carelog`. For example, from the chosen environment, with protected tfvars already provisioned:

```powershell
$env:AWS_PROFILE = 'rankun-admin'
terraform init -input=false -backend-config='bucket=ranikun-dev-tfstate-124495093425' -backend-config='region=ap-northeast-2' -backend-config='allowed_account_ids=["124495093425"]'
terraform plan -input=false -lock-timeout=5m -var-file='<protected-tfvars>' -out='<secure-plan-path>'
```

A real DEV plan has not been run. Backend key and complete variable inputs must be independently matched to the intended environment before planning. Plan files can contain sensitive data and require protected storage. The latest candidate commit is for review and cannot be deployed without resolving the preceding gaps.

## Binding, least-privilege and release-path update

The Carelog input example binds Spring to `127.0.0.1`, removes the app container port mapping, and assigns the nginx sidecar task-IP ports 8080 and 8443. Separate optional sets extend only the execution role ECR repository, Secrets Manager ARN and KMS key ARN scopes. Defaults remain empty. Secret values must never be supplied as Terraform inputs. Core init must be built FROM the exact Core image digest and mount its derived trust store read-only into the Core application, with SUCCESS dependency. The example trustStore password is the default public JDK store integrity password, not an enrollment credential.

On 2026-11-23 a local trust-init image built from Core digest sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf copied the source cacerts and imported a synthetic CA successfully. The source had 117 entries and the result had 118, including the synthetic CA. This verifies init execution and store preservation, not a Core JDK HTTPS handshake or application registration. Windows CRLF originally caused init failure; `.gitattributes` now forces LF on scripts.

The release workflow obtains the current service task definition, replaces only the workload image, and registers a new revision. Terraform baseline changes do not automatically modify the service task revision because task_definition is ignored. A reviewed service revision containing the new sidecar, init container, volumes and settings must be registered and selected through an authorized rollout before an image-only release can inherit them. No revision was registered or selected during this candidate work.

Carelog baseline vs candidate plans with reconstructed state inputs both reported 9 additions, 0 changes, and 10 deletions. This is a diagnostic of existing configuration drift, not approved inputs or an applyable plan. Platform plan remains blocked by missing protected inputs and absent ACM certificate.
