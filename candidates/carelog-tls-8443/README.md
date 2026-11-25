# carelog DEV TLS images (Core enrollment and claims over 8443)

Image sources for the transition described in `environments/dev/carelog/README.md`
(branch `claude/great-heisenberg-u3i75y-dev-carelog`). Nothing here is deployed. Terraform is not changed.

- `proxy/`: front proxy sidecar (nginx). TLS on task IP:8443 for Core. Plain front on task IP:8080 for Gateway, with
  Core claims only during the rollback window.
- `trust-init/`: init image. Copies the Core image's `cacerts` and adds the Carelog DEV CA. It takes the Core digest as a build argument.
- `build/build-images.sh`: builds both images. Refuses a tag-style Core reference.
- `tests/`: test PKI, negative entrypoint cases, trust-init cases, and a host-mode functional suite (nginx and
  JDK HttpClient). Run with `tests/run-all.sh <workdir>`.

## 1. Mechanism for 8080 (decision)

Facts that drive it (carelog-be, read-only):

- `EnrollmentSecurityConfiguration` is enabled for the whole app by `carelog.identity.enrollment.enabled`. Its filter
  matches `/internal/v1/identity/carelog/enrollments/**` on every port. Spring has no per-port switch.
- `InternalIdentitySecurityConfiguration` serves `GET /internal/identity/claims/*` with the same app on every port.
- Gateway routes `Path=/api/**` to carelog (`platform-services` gateway `application.yml`). Gateway needs task IP:8080.
- `server.address` defaults to `0.0.0.0` (`application-prod.yml:32`). The app listens on all interfaces by default.

Options:

| Option | Result |
| --- | --- |
| (a) Keep the app on task IP:8080 and rely on the Core SG | Rejected. The SG cannot see paths. During transition Core keeps 8080 for claims, so Core could reach enrollment on 8080. |
| (b) Turn enrollment off on 8080 inside carelog-be | Rejected. Enrollment is one app-wide chain. A per-port check needs code, and a header such as `X-Forwarded-Proto` would be forgeable from 8080. |
| (c) App bound to loopback; one nginx front on task IP serves 8080 and 8443 | **Chosen.** |

**Chosen design (c):**

- carelog-be: `SERVER_ADDRESS=127.0.0.1`. The app is reachable only inside the task netns on `127.0.0.1:8080`.
- Front proxy, `TASK_IP:8080` (plain): Gateway pass-through for `^/api/`. Every `/api/v1/internal` path is denied
  (case-insensitive, decoded `$uri`). Transition only: exact UUID `GET .../identity/claims/{id}`.
  Enrollment is never allowed here.
- Front proxy, `TASK_IP:8443` (TLS, Core only): UUID-exact `PUT .../enrollments/{id}` and `GET .../claims/{id}`.
  Every other path and method is 403. Any `%` in the request URI is refused, because `$uri` is decoded before matching.
- Both listeners proxy to `127.0.0.1:8080` with no URI part in `proxy_pass`, so the app receives the raw request target.

**Correction to the contract:** `environments/dev/carelog/README.md` says the image must have "no listener on 8080 on
the task IP". That cannot hold while Gateway uses `TASK_IP:8080`, which it does today. The task IP:8080 listener
stays. It becomes the proxy front rather than the app. The contract text must change to say so.

**Trade-offs:**

- Gateway traffic now passes through nginx. Body limit is 10 MB, which needs checking against carelog-be limits.
  Path encodings other than `%2e %2f %3b %5c %00` are passed through on 8080.
- The app sees peer address `127.0.0.1` for every request. Check any IP-based logic (audit, rate limit). X-Forwarded-For is not set by this template.
- The front uses a denylist for the internal namespace. Gateway's route is `Path=/api/**`, so an allowlist would have
  to enumerate every carelog endpoint. An unknown internal endpoint fails closed (403).
- During the window, Core can still reach non-internal APIs on 8080. Those APIs are authenticated by the app.
  Core holds no product credentials, so this is accepted for the window only.

## 2. Transition sequence and what lane A must keep

Lane A (platform-infra Terraform) must keep these until the rollback window closes:

1. Core SG ingress `core_claims` on 8080 (old Core revision `:3` uses `http://...:8080` for claims).
2. The old Core revision's claims base URL unchanged (`http://<svc>.<ns>:8080`).
3. Gateway SG ingress on 8080 (unchanged).
4. Proxy env `CORE_CLAIMS_ON_8080=true` (default) during the window.

Sequence:

1. Deploy the proxy with the app on loopback (`SERVER_ADDRESS=127.0.0.1`). Gateway, old Core and new Core keep working.
2. Roll the new Core revision to `https://<svc>.<ns>:8443` for enrollment and claims. Add the Core SG rule on 8443. Install the trust store (section 4).
3. Verify new Core enrollment and claims over 8443. Verify old Core claims over 8080 still works.
4. After the window: remove the Core SG rule on 8080, set `CORE_CLAIMS_ON_8080=false`, and redeploy the proxy. Keep the
   8080 listener, because Gateway needs it.

Do not remove the 8080 listener in step 4. Removing it would break Gateway.

## 3. Required changes outside this branch

- **carelog-be (env):** `SERVER_ADDRESS=127.0.0.1`. Without it, nginx cannot bind `TASK_IP:8080`.
- **carelog-be (not env-settable):** management server `address: 0.0.0.0` (`application-prod.yml:87`). The SG does
  not open 8081, but the port is still bound on all interfaces. Changing it needs a yml or code change in carelog-be.
- **carelog-be (pre-existing blocker, from `environments/dev/carelog/README.md`):** `/run/rds-ca.pem` is required by
  `sslrootcert`. It is unrelated to this lane, but DEV boot fails without it.
- **Terraform (lane A):** two containers in the carelog task. `carelog-tls-front` holds the 8080/8443 port mappings,
  with the bundle secret and `TLS_EXPECTED_DNS_SAN` set. The app has no published port.
  The proxy healthcheck is the command in `proxy/Dockerfile`.
- **Core task (lane A):** init container `trust-init` (essential=false) with the Core image digest, `/run/carelog-trust`
  as a volume shared read-only with Core, and `-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts` (JKS; password
  `changeit`, the public JDK default). The derived store is a superset of the Core base store, so other outbound TLS is unaffected.
- **SAN decision:** the README contract host is `<service_name>.<namespace_name>`. The earlier candidate defaulted to
  `ranikun-carelog-dev-api.dev.internal`. This branch requires `TLS_EXPECTED_DNS_SAN` with no default. The leaf SAN
  must be the same name, and Core's URL must use the same name.

## 4. Secrets and certificates

**TLS bundle** (`ranikun/dev/carelog/enrollment-tls/server-bundle`, one Secrets Manager string, JSON):

```json
{ "tls_certificate": "-----BEGIN CERTIFICATE-----\n...leaf only...\n-----END CERTIFICATE-----\n",
  "tls_private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n" }
```

- Leaf only, with no chain. The entrypoint requires exactly one certificate with `CA:FALSE`, a SAN equal to `TLS_EXPECTED_DNS_SAN`,
  a valid date, and a matching key. ECDSA P-256 is suggested.
- Rotation: write a new secret version, then force a new deployment of the proxy. The entrypoint reads at start.
- No CA private key is stored in any secret that tasks can read.

**CA recommendation: ACM Private CA.** It keeps the CA key in AWS-managed HSM, audits issuance in CloudTrail, and
avoids a CA key on disk or in state. The trade-off is a fixed monthly CA fee and an issuance role
(`acm-pca:IssueCertificate`, `acm-pca:GetCertificate`) that belongs to an operator or CI principal and never to a task role.
Confirm the current price before choosing. A self-managed offline root is cheaper, but CA custody then depends on a manual process.
Use this only for a throwaway dev.

The leaf is generated outside AWS. Its key is created on the issuing host, the CSR is signed by PCA, and the bundle is
written to Secrets Manager. The local key file is then deleted. Nothing else holds it.

Expiry: alert well before `notAfter`. The entrypoint fails closed on an expired leaf.

## 5. Permissions (boundary v4 statements)

Placeholders in `<>` must be replaced with real ARNs from the Terraform outputs. Do not use wildcards for secret
ARNs, because Secrets Manager suffixes are random.

**Carelog task execution role, proxy container** (add to `carelog-tls-boundary`):

```json
[
  { "Sid": "TlsFrontEcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
  { "Sid": "TlsFrontImagePull", "Effect": "Allow",
    "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
    "Resource": "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy" },
  { "Sid": "TlsFrontBundleRead", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
    "Resource": "<exact ARN of ranikun/dev/carelog/enrollment-tls/server-bundle, with its suffix>" },
  { "Sid": "TlsFrontBundleKms", "Effect": "Allow", "Action": "kms:Decrypt",
    "Resource": "<CMK ARN, only if the secret uses a customer-managed key>",
    "Condition": { "StringEquals": { "kms:ViaService": "secretsmanager.ap-northeast-2.amazonaws.com" } } }
]
```

Log delivery: check that the existing log-group statement covers the proxy container's stream. Not verified here.

**Carelog task execution role, app container:** no new actions. The enrollment and claims secret ARNs already exist.
Confirm the `ranikun/dev/carelog/enrollment-service-XXXXXX` suffix from `describe-secret`. The candidate file has a placeholder.

**Core task execution role, trust-init init container:** no new secret. ECR pull on
`arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init` (already in
`candidates/carelog-tls/tests/iam/terraform-core-execution.json`). The CA bundle is inside the image.

**Issuance (operator or CI only, not a task role):** `acm-pca:IssueCertificate` and `acm-pca:GetCertificate` on the CA
ARN, plus `secretsmanager:PutSecretValue` on the bundle secret ARN. The CA ARN and the bundle ARN must be exact.

**ECR:** create `ranikun/carelog/tls-proxy` and `ranikun/platform/core-trust-init` with immutable tags, scan on push,
and a lifecycle policy. Task roles pull by digest. Terraform pins the digests printed by `build/build-images.sh`.

## 6. Build and publish

1. Get the Core digest from the Core task definition that runs in DEV (`repo@sha256:...`). Tags are refused.
2. `CORE_IMAGE=<digest> CA_BUNDLE=<public CA PEM> SOURCE_SHA=<commit> PROXY_REPO=<ecr>/ranikun/carelog/tls-proxy TRUST_REPO=<ecr>/ranikun/platform/core-trust-init build/build-images.sh`
3. Put the printed digests into the carelog and Core root variables. Run `terraform plan`. Release owns the deploy.

## 7. Test evidence (this sandbox)

`tests/run-all.sh` (host mode):

- `test-entrypoint-negative.sh`: 12 of 12. Refusals for wrong SAN, other-SAN cert, expired, swapped fields, CA in leaf slot,
  key mismatch, chain in cert slot, wildcard name, empty name, non-JSON bundle, invalid claims flag. Valid bundle reaches the metadata fetch.
- `test-trust-init.sh`: 10 of 10. Store grows by exactly 1, base unchanged, output 644, no working files. Refused: empty,
  non-CA leaf, expired CA, bundle with private key, non-PEM, unbalanced PEM.
- `test-proxy-host.sh`: 66 of 66 across both claims modes. Includes curl and JDK HttpClient (`TlsClient.java`, derived truststore, SAN and hostname verified).
  - 8443: enrollment PUT and claims GET 200. Enrollment GET, claims PUT, gateway path, non-UUID, `//`, `%2f`, `;`, dot segment,
    trailing slash, `%69nternal` all 403. Plain HTTP 400. Untrusted CA and wrong hostname are refused client-side.
  - 8080: enrollment PUT and its bypass forms 403. Gateway GET and POST 200. Claims 200 in transition and 403 after the window.
  - Only 127.0.0.1:8080 is bound by the app stand-in. No wildcard listener on 8080 or 8443.

A real defect was found and fixed by the suite. On 8443 an encoded internal path (`%69nternal`) passed the allowlist,
because `$uri` is decoded before matching. The fix denies any `%` on 8443, which Core never needs.

`DOCKER=1 tests/test-trust-init.sh`: the trust-init image builds on a stand-in base and carries the core-base label
and entrypoint.

**Not verified here:**

- The proxy image was not built. The Alpine mirror is blocked in this sandbox (`apk` fails with permission denied), so
  the pinned `jq` and `openssl` versions are unverified. `docker build --check proxy/` is clean.
- nginx tests ran on host nginx 1.24, not the image's 1.27.
- The Core image and carelog-be were not run. Spring-side behaviour (`SERVER_ADDRESS`, enrollment chain) is inferred from source.
- Nothing was run against AWS.

## 8. Reviewer checklist

- Replace the `ranikun-carelog-dev-api.dev.internal` default in the old candidate with `TLS_EXPECTED_DNS_SAN` (this branch has no default).
- Confirm `SERVER_ADDRESS=127.0.0.1` in the carelog task environment.
- Confirm old Core has no enrollment client, so the 8080 enrollment block cannot break it.
- Check carelog-be request-size limits against the 10 MB front limit.
- Check Gateway query strings for `;`, `..`, or encoded slashes. These are refused on both listeners.
