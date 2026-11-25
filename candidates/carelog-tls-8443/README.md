# carelog DEV TLS image (Core enrollment and claims over 8443)

Image sources for the transition described in `environments/dev/carelog/README.md`
(branch `claude/great-heisenberg-u3i75y-dev-carelog`). Nothing here is deployed. Terraform is not changed.

- `proxy/`: front proxy sidecar (nginx), container name `carelog-tls-proxy`. Listens on task IP:8443 (TLS) only.
- `trust-init/`: init image. Copies the Core image's `cacerts` and adds the Carelog DEV CA. Takes the Core digest as a build argument.
- `build/build-images.sh`: builds both images. Refuses a tag-style Core reference.
- `tests/`: test PKI, entrypoint negative cases, trust-init cases, and a host-mode functional suite (nginx and JDK
  HttpClient). Run with `tests/run-all.sh <workdir>`.

## 1. Decision: 8443 only; app-side loopback check for internal endpoints

The proxy no longer fronts 8080. The app serves Gateway directly, and the internal endpoints are guarded in the app.

- carelog-be binds `0.0.0.0:8080` (default). Gateway reaches it on task IP:8080 with no proxy in between.
- carelog-be accepts internal endpoints (`/api/v1/internal/**`) from **loopback peers only**. This is the carelog-be lane.
  The claims transition for old Core is an app-side flag, so the proxy carries no claims logic.
- The proxy listens on task IP:8443 (TLS) and forwards to `127.0.0.1:8080`. The app sees loopback for every Core
  request, so the loopback check passes, and the proxy allowlist decides which paths reach the app.

Why this and not a front on 8080: Core and Gateway share task IP:8080 and Core's SG cannot see paths. A front on 8080
would need a denylist that enrollment could slip past, and any `X-Forwarded-Proto` header is forgeable from 8080.
Moving the check into the app makes it path-independent and removes the front from the 8080 path entirely.

**Costs, stated plainly:**

- **Defense in depth on 8080 is gone.** Anything that reaches task IP:8080 is judged by the app's loopback check alone.
  A bug in that check exposes enrollment to Gateway and Core. The check needs its own test in carelog-be.
- **Sequencing blocker.** Until carelog-be's loopback enforcement is deployed, 8080 serves enrollment to every peer
  the SG allows (Gateway and Core). Deploy the carelog-be change before, or together with, this proxy. Do not deploy
  this proxy against an app that lacks the check.
- The app sees peer `127.0.0.1` for all Core traffic on 8443. Anything keyed on peer IP for Core (audit, rate limit) must
  account for it. No `X-Forwarded-For` is set.
- `SERVER_ADDRESS` is no longer needed. The app keeps the default bind.

## 2. Contract changes outside this branch

Lane A (platform-infra Terraform) and carelog-be must change together with this image:

- **Container names:** `carelog-tls-proxy` (proxy) and the existing app container. Port mappings: proxy `8443`, app `8080`
  (awsvpc, no host ports).
- **Core SG:** ingress on 8443 for enrollment and claims. Keep the 8080 ingress for old Core claims during the window (section 7).
- **Gateway SG:** ingress on 8080 unchanged. Gateway now targets the app directly.
- **`environments/dev/carelog/README.md`:** the text "no listener on 8080 on the task IP" must change. The app listens on
  task IP:8080 for Gateway. The proxy has no 8080 listener. The rule that matters is the app's loopback check.
- **Management port:** carelog-be's management server is bound to `0.0.0.0:8081` (`application-prod.yml:87`, not
  settable by env). The SG does not open 8081, but the port is still bound on every interface. The proxy health route
  (`127.0.0.1:9180/healthz`) calls `127.0.0.1:8081`. Changing the management bind needs a carelog-be yml change. It is a
  pre-existing item, not part of this image.
- **Pre-existing DEV blocker, unrelated to this lane:** `/run/rds-ca.pem` is required by `sslrootcert`. DEV boot fails without it.

## 3. Proxy behaviour (`proxy/nginx.conf.template`)

Requests are forwarded raw (`proxy_pass` to the `carelog_app` upstream, no URI part), so the app receives the exact request target.

- **Allowlist (exact):** `PUT /api/v1/internal/v1/identity/carelog/enrollments/{uuid}` and
  `GET /api/v1/internal/identity/claims/{uuid}`. The UUID is matched as a whole with `\z`. A `$` anchor would also match
  before a trailing newline, so `%0a` could slip past. Everything else is 403.
- **Path-only deny (raw `$request_uri`, query string never checked):** any `%` in the path (covers `%2e %2f %3b %5c %00 %0a %0d %25`),
  `;`, backslash, `..`, `/./`, a trailing `/.`, and `//`. A query string on an allowed path passes through unchanged.
- **Host check:** `$host` (lower-case, port dropped) must equal `TLS_EXPECTED_DNS_SAN`. Anything else gets **421**.
  The JDK sends `Host: name:8443`, which still matches.
- **Denials:** 403 with body `{"error":"forbidden"}` and `application/json`. 421 has `{"error":"misdirected"}`.
  Plain HTTP to the TLS port gets nginx's 400. An encoded NUL is refused by nginx's parser with 400 before any location logic runs.
- **Upstream:** keepalive 8, `proxy_http_version 1.1`, `Connection ""`.
- **Timeouts:** connect 5s, send 60s, read 60s. Read timeout is 60s because the app answers enrollment and claims well inside that.
- **Retries:** `proxy_next_upstream off`. Enrollment is a PUT and must not be replayed silently.
- **Logging:** `carelog_tls` format with time, client address, method, status, timings and upstream status. No path and no query
  string, because the path carries the account UUID. Troubleshooting a 403 means checking the path in the source, not the log.
- **Body limit:** 4 KB on 8443.

## 4. TLS bundle, CA and secrets

**TLS bundle** (`ranikun/dev/carelog/enrollment-tls/server-bundle`, one Secrets Manager string, JSON):

```json
{ "tls_certificate": "-----BEGIN CERTIFICATE-----\n...leaf only...\n-----END CERTIFICATE-----\n",
  "tls_private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n" }
```

- Leaf only, no chain. The entrypoint requires exactly one certificate with `CA:FALSE`, a SAN equal to `TLS_EXPECTED_DNS_SAN`,
  a valid date, and a matching key. ECDSA P-256 is suggested.
- `TLS_EXPECTED_DNS_SAN` has no default. It is `<service_name>.<namespace_name>`, and Core's URL must use the same name.
- Rotation: write a new secret version, then force a new deployment of the proxy. The entrypoint reads at start.
- No CA private key is stored in any secret that tasks can read.

**CA recommendation: ACM Private CA.** It keeps the CA key in AWS-managed HSM and audits issuance in CloudTrail.
Trade-offs: a fixed monthly CA fee, and an issuance principal (operator or CI) that must exist outside the task roles.
A self-managed offline root is cheaper but makes CA custody a manual process. Use that only for a throwaway dev.

**Name constraints (recommended, not yet verified against PCA):** Core's truststore will trust this CA for every hostname
Core dials, so a compromised CA can impersonate any name. Put a critical `nameConstraints` extension on the CA certificate
with `permittedSubtrees` limited to the Carelog DEV DNS zone. Java's PKIX path validation enforces it, so a leaf for any
other name is refused by Core. Check first whether PCA can issue a CA certificate that carries this extension. If it cannot,
use a self-managed root or accept the wider blast radius and record it. The test PKI in this repo does not carry name constraints,
so no test covers this item.

## 5. Permissions (boundary statements)

Placeholders in `<>` must be replaced with real ARNs from the Terraform outputs. No wildcards on secret ARNs, because
Secrets Manager suffixes are random.

**Carelog task execution role, proxy container:**

```json
[
  { "Sid": "TlsProxyEcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
  { "Sid": "TlsProxyImagePull", "Effect": "Allow",
    "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"],
    "Resource": "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy" },
  { "Sid": "TlsProxyBundleRead", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
    "Resource": "<exact ARN of ranikun/dev/carelog/enrollment-tls/server-bundle, with its suffix>" },
  { "Sid": "TlsProxyBundleKms", "Effect": "Allow", "Action": "kms:Decrypt",
    "Resource": "<CMK ARN, only if the secret uses a customer-managed key>",
    "Condition": { "StringEquals": { "kms:ViaService": "secretsmanager.ap-northeast-2.amazonaws.com" } } }
]
```

Log delivery: check that the existing log-group statement covers the proxy container's stream. Not verified here.

**Carelog task execution role, app container:** no new actions.

**Core task execution role, trust-init init container:** no new secret. ECR pull on
`arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init`. The CA bundle is inside the image.

**Issuance (operator or CI only, never a task role):**

```json
[
  { "Sid": "PrivateCaIssueLeaf", "Effect": "Allow", "Action": "acm-pca:IssueCertificate",
    "Resource": "<CA ARN>",
    "Condition": { "StringEquals": { "acm-pca:TemplateArn": "<end-entity server-auth template ARN for this region>" } } },
  { "Sid": "PrivateCaReadCert", "Effect": "Allow", "Action": "acm-pca:GetCertificate", "Resource": "<CA ARN>" },
  { "Sid": "BundleWrite", "Effect": "Allow", "Action": "secretsmanager:PutSecretValue",
    "Resource": "<exact ARN of the bundle secret>" }
]
```

The `acm-pca:TemplateArn` condition key and the template ARN are not verified against the account here.

**ECR:** create `ranikun/carelog/tls-proxy` and `ranikun/platform/core-trust-init` with immutable tags, scan on push, and a
lifecycle policy. Task roles pull by digest. Terraform pins the digests printed by `build/build-images.sh`.

## 6. Build and publish

1. Get the Core digest from the Core task definition that runs in DEV (`repo@sha256:...`). Tags are refused.
2. `CORE_IMAGE=<digest> CA_BUNDLE=<public CA PEM> SOURCE_SHA=<commit> PROXY_REPO=<ecr>/ranikun/carelog/tls-proxy TRUST_REPO=<ecr>/ranikun/platform/core-trust-init build/build-images.sh`
3. Put the printed digests into the carelog and Core root variables. Run `terraform plan`. Release owns the deploy.

## 7. Rollout and rollback

Rollout, in order:

1. Deploy carelog-be with loopback-only internal endpoints. Old Core claims stay allowed through the app flag during the window.
2. Deploy the proxy image (8443 only) together with the app change above.
3. Roll new Core to `https://<svc>.<ns>:8443` for enrollment and claims. Add the Core SG rule on 8443. Install the trust store (section 4).
4. Verify new Core enrollment and claims over 8443. Verify old Core claims over 8080 still work through the app flag.
5. After the window: remove the Core SG rule on 8080, turn the app flag off, and redeploy.

Rollback:

- **Mixed state is broken.** The old proxy (8080 front) binds task IP:8080 and the new app binds `0.0.0.0:8080`. Both cannot
  run. Rolling the proxy back means rolling the app bind back to `SERVER_ADDRESS=127.0.0.1` in the same deploy.
  The new proxy with an app still on loopback leaves Gateway without a route on 8080.
- **Core rollback** (new Core to old 8080 claims) needs only the app flag and the 8080 Core SG rule kept during the window. No proxy change.
- **Proxy rollback is not a flag flip.** Revert the proxy image and the app bind together.

## 8. Test evidence (this sandbox)

`tests/run-all.sh` (host mode) on this commit:

- `test-entrypoint-negative.sh`: 11 of 11. Refusals for wrong SAN, other-SAN cert, expired, swapped fields, CA in leaf slot,
  key mismatch, chain in cert slot, wildcard name, empty name, non-JSON bundle. Valid bundle reaches the metadata fetch.
- `test-trust-init.sh`: 10 of 10 in host mode, plus 3 in Docker mode (`DOCKER=1`, stand-in base): 13 of 13 in that mode.
  Store grows by exactly 1, base unchanged, output 644, no working files. Refused: empty, non-CA leaf, expired CA, bundle with a private key, non-PEM, unbalanced PEM.
- `test-proxy-host.sh`: 37 of 37 (host nginx 1.24, JDK HttpClient). Covers:
  - Allowed: enrollment PUT and claims GET 200, including a query string with `;//` and `..`. Host with port 200.
  - Denied 403 with JSON body: enrollment GET, claims PUT, gateway path, non-UUID, `//` bypasses, `;`, `..`, `%2e%2e`, `/./`, trailing `/.` and `/`,
    `%69nternal`, UUID followed by `%0a`, `%0d`, `%25`, `%00`-in-path (400 from nginx).
  - 421 for a mismatched Host. Plain HTTP 400. Untrusted CA and wrong hostname refused client-side.
  - Listener scope: no proxy listener on task IP:8080 (connection refused), no `listen ...8080` in the rendered config, TLS bound to task IP:8443 only.
  - JDK client: enrollment PUT and claims GET pass with SAN and hostname verified. The JDK default truststore rejects the test CA.
- Also run: the template under the pinned `nginx:1.27.5` image (`nginx -t` OK), and a smoke test of the same rendered template
  in that image with host networking. The results match the host-nginx run: JSON 403 and 421 bodies, query pass-through, `%0a`/`/./` denied,
  access log without path.

A real defect was found and fixed in an earlier iteration: on 8443 an encoded internal path (`%69nternal`) passed the allowlist,
because `$uri` is decoded before matching. The path-only deny denies any `%` in the path, so the fix holds.

**Not verified here:**

- **The proxy image was not built.** The sandbox cannot reach `dl-cdn.alpinelinux.org` (DNS error), so the `apk add` of
  `jq=1.8.2-r0` and `openssl=3.3.7-r2` failed on "no such package". The base image is Alpine 3.21.3. Whether those two pins exist
  on that branch is unverified. The base digest pulls fine.
- The Core image and carelog-be were not run. The app-side loopback check, the claims flag and the app bind are carelog-be's, and
  nothing here tests them.
- The `acm-pca:TemplateArn` condition and the PCA name-constraints feasibility (section 4 and 5) are not verified against AWS.
- Nothing was run against AWS. No deploy, no Terraform.

## 9. Reviewer checklist

- Replace `ranikun-carelog-dev-api.dev.internal` in any older candidate with `TLS_EXPECTED_DNS_SAN` (this branch has no default).
- Confirm carelog-be's loopback check ships before or with this proxy (section 1, sequencing blocker).
- Confirm old Core has no enrollment client, so the 8080 enrollment path it never uses cannot break it.
- Check carelog-be request-size limits against Gateway traffic. Gateway no longer passes through nginx, so the 10 MB front limit no longer applies there.
- Confirm the alpine `jq` and `openssl` pins exist on the base's Alpine branch (section 8, not verified).
