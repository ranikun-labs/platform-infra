# carelog DEV TLS image (Core enrollment and claims over 8443)

Image sources for the transition described in `environments/dev/carelog/README.md`
(branch `claude/great-heisenberg-u3i75y-dev-carelog`). Nothing here is deployed. Terraform is not changed.

- `proxy/`: front proxy sidecar (nginx), container name `carelog-tls-proxy`. Listens on task IP:8443 (TLS) only.
- `ca/`: self-managed DEV CA. `make-root.sh` (offline root with nameConstraints) and `issue-leaf.sh` (90-day leaf, bundle JSON).
- `trust-init/`: init image. Copies the Core image's `cacerts` and adds the Carelog DEV CA. Takes the Core digest as a build argument.
- `build/build-images.sh`: builds both images. Refuses a tag-style Core reference.
- `tests/`: test PKI, entrypoint negative cases, trust-init cases, a host-mode functional suite (nginx and JDK
  HttpClient), and self-managed CA cases. Run with `tests/run-all.sh <workdir>`.

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
- **Management port:** carelog-be's management server is bound to `0.0.0.0:8081` by `application-prod.yml:87`. Per the
  review, the environment variable `MANAGEMENT_SERVER_ADDRESS=127.0.0.1` overrides that yml value, so the task definition
  can bind management to loopback without a code change. The proxy health route (`127.0.0.1:9180/healthz`) calls
  `127.0.0.1:8081`, which still works on loopback. Verify the override in carelog-be before relying on it. It is not
  verified in this lane.
- **Netns invariant:** no container in the carelog task network namespace may relay external traffic to `127.0.0.1`
  (for example a cloudflared or any other tunnel sidecar). Anything that does would reach the loopback-trusted internal
  endpoints from outside. Lane A must not add such a container to this task. Reviewed, not enforced by this image.
- **Pre-existing DEV blocker, unrelated to this lane:** `/run/rds-ca.pem` is required by `sslrootcert`. DEV boot fails without it.

## 3. Proxy behaviour (`proxy/nginx.conf.template`)

Requests are forwarded raw (`proxy_pass` to the `carelog_app` upstream, no URI part), so the app receives the exact request target.

- **Allowlist (exact):** `PUT /api/v1/internal/v1/identity/carelog/enrollments/{uuid}` and
  `GET /api/v1/internal/identity/claims/{uuid}`. The UUID is matched with `\z`. A `$` anchor also matches before a trailing
  newline, so a decoded `%0a` could slip past. Everything else is 403.
- **Path-only deny (raw `$request_uri`, query string never checked):** any `%` in the path (covers `%2e %2f %3b %5c %00 %0a %0d %25`),
  `;`, `#`, backslash, `..`, `/./`, a trailing `/.`, and `//`. A query string on an allowed path passes through unchanged.
  `#` is never valid in a request target. Its rule is defence in depth only: the anchored allowlist already refuses `#x` tails.
- **Host check:** `$host` (lower-case, port dropped) must equal `TLS_EXPECTED_DNS_SAN`. Anything else gets **421**.
  The JDK sends `Host: name:8443`, which still matches.
- **Denials, all JSON:** 403 `{"error":"forbidden"}`, 413 `{"error":"payload_too_large"}` (body over 4 KB), 421 `{"error":"misdirected"}`.
  Plain HTTP to the TLS port gets nginx's 400. An encoded NUL is refused by nginx's parser with 400 before location logic runs.
- **Upstream:** keepalive 8, `keepalive_timeout 30s` (below Tomcat's 60s keep-alive, so nginx does not reuse a socket Tomcat has
  closed), `proxy_http_version 1.1`, `Connection ""`.
- **Timeouts:** connect 5s, send 60s, read 60s. The read timeout matches the app's answer window for enrollment and claims.
- **Retries:** `proxy_next_upstream off` at the proxy. The enrollment PUT is never replayed by nginx.
  **Core side (not this image):** Core may retry a 5xx once, and only for the idempotent enrollment PUT. A retry after a timeout
  is the only case where the same PUT reaches the app twice. Confirm this with the Core owner before go-live.
- **Logging:** `carelog_tls` format with time, client address, method, status, timings and upstream status. No path and no query
  string, because the path carries the account UUID. A 403 is diagnosed from the source, not from the log.
- **Body limit:** 4 KB on 8443.

## 4. TLS bundle and the DEV CA (self-managed, `ca/`)

**Decision: self-managed DEV CA, not ACM Private CA.** The CA is an offline root on an operator host. Nothing in CI, the repo, a
task volume or a task-readable secret holds its key. ACM PCA is not used.

**TLS bundle** (`ranikun/dev/carelog/enrollment-tls/server-bundle`, one Secrets Manager string, JSON):

```json
{ "tls_certificate": "-----BEGIN CERTIFICATE-----\n...leaf only...\n-----END CERTIFICATE-----\n",
  "tls_private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n" }
```

The entrypoint requires exactly one certificate, a leaf, with a SAN equal to `TLS_EXPECTED_DNS_SAN` and a matching key.
`TLS_EXPECTED_DNS_SAN` has no default. It is `<service_name>.<namespace_name>`, and Core's URL uses the same name.

**Scripts:**

- `ca/make-root.sh`: `NAMESPACE`, `SERVICE_HOST`, `OUT_DIR`. Creates an ECDSA P-256 root, valid 730 days, with
  `basicConstraints=critical,CA:TRUE,pathlen:0`, `keyUsage=critical,keyCertSign,cRLSign`, and
  `nameConstraints=critical` with permitted `DNS:.<namespace>` and `DNS:<service host>` and excluded `IP:0.0.0.0/0` and `IP:::/0`.
  Writes `root.key` (0600), `root.crt`, `ca-bundle.pem` (public, for trust-init) and `constraints.env`.
  It refuses an `OUT_DIR` inside the git worktree and a non-empty `OUT_DIR`.
- `ca/issue-leaf.sh`: `CA_DIR`, `HOST`, `OUT_DIR`. Issues a 90-day leaf (`CA:FALSE`, `EKU serverAuth`, `SAN=HOST`,
  `keyUsage=digitalSignature`). Refuses a `HOST` outside the constraints in `constraints.env`. Verifies the chain before writing.
  Writes `leaf.crt`, `leaf.key` (0600) and `bundle.json` (0600, the two-field Secrets Manager shape).
  The leaf key is generated on the operator host and never leaves `OUT_DIR`.

**Finding: nameConstraints is not enforced by the JDK on a trust anchor.** `test-selfca.sh` measures this, with JDK 17 HttpClient:

| Chain shape (truststore holds only the root) | Leaf for `evil.example.org` | IP-SAN leaf `127.0.0.2` |
| --- | --- | --- |
| root issues leaf directly (the shipped `make-root` + `issue-leaf` shape) | accepted (rc 0): constraint not applied | accepted (rc 0): constraint not applied |
| root -> constrained issuing CA (pathlen 0) -> leaf, server sends leaf + issuing CA | **refused** (rc 2) | not tested in the two-tier case |

So the root's nameConstraints, as shipped, are documentation and not a control. To make the constraint enforceable, the
constrained CA must be an intermediate that the server sends in the chain. **This is a follow-up, not done here:** the
entrypoint currently requires exactly one certificate, so it would need to accept leaf + issuing CA (with the leaf first and
only CA certificates after it). That change, its negative tests and a rotation to a two-tier layout are a separate task.
Until then, the trust boundary is the operator process and the key custody, not the name constraint.

The in-namespace sibling case is also measured. A leaf for `other.test.internal`, signed by the same root, is accepted for its
own name (the namespace is allowed) and refused when presented for `carelog-dev.test.internal` (hostname mismatch). Name
constraints do not stop in-namespace siblings. Hostname verification does.

**Trust-init:** only `ca-bundle.pem` goes into the image (`CA_BUNDLE=... build/build-images.sh`). It is public. trust-init
accepts a root with `CA:TRUE` and a valid date, and the store grows by one (tested).

**Custody:**

- After `make-root.sh`, move `root.key` to offline storage (password-manager attachment or encrypted offline medium). Keep
  one tested copy off the operator host. Then delete the host copy (Linux: `shred -u`; macOS: `rm -P`).
- Never store `root.key` in the repo, a task volume, Secrets Manager or CI variables.
- `issue-leaf.sh` needs the key on the issuing host only for the duration of issuance.

**Rotation:**

- **Leaf (every 90 days):** on the operator host, `CA_DIR=<root dir> HOST=<SAN> OUT_DIR=<new empty dir> ca/issue-leaf.sh`.
  Put `bundle.json` as a new version of the bundle secret (`aws secretsmanager put-secret-value --secret-id <ARN> --secret-string file://bundle.json`).
  Force a new proxy deployment, because the entrypoint reads at start. Shred `leaf.key` and `bundle.json` locally after the put.
  Alert at 30 days before `notAfter`. The entrypoint fails closed on an expired leaf.
- **Root (every 2 years, or on suspected compromise):** `make-root.sh` into a new `OUT_DIR`. Build a trust-init image that holds
  both the old and new `ca-bundle` certificates (`CA_BUNDLE` accepts a multi-certificate PEM). Roll Core to that image. Issue
  new leaves from the new root. Roll the proxy. After the last old leaf expires, remove the old root from the bundle and rebuild.
  On compromise, skip the overlap: remove the old root from the bundle at once, roll Core and the proxy, and accept the outage.

## 5. Minimal IAM boundary

Replace `<...>` with the Terraform outputs. No wildcard resource except where ECR requires `*`. No statement for any **task
role**: the carelog and Core task roles gain nothing from this change.

**(a) Carelog task execution role, proxy container** (the `carelog-tls-proxy` container pulls its image and reads the bundle):

```json
[
  { "Sid": "ProxyEcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
  { "Sid": "ProxyImagePull", "Effect": "Allow",
    "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
    "Resource": "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy" },
  { "Sid": "ProxyBundleRead", "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
    "Resource": "<exact ARN of ranikun/dev/carelog/enrollment-tls/server-bundle, with its suffix>" }
]
```

Add `kms:Decrypt` on the CMK only if the secret uses a customer-managed key, with `kms:ViaService` set to
`secretsmanager.ap-northeast-2.amazonaws.com`. The app container gets no new action.

**(b) Core task execution role, trust-init init container:**

```json
[
  { "Sid": "TrustInitEcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
  { "Sid": "TrustInitImagePull", "Effect": "Allow",
    "Action": ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"],
    "Resource": "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init" }
]
```

**(c) Task roles:** nothing. The proxy and Core processes read no AWS API for this change.

**(d) Operator and CI (never a task role):**

```json
[
  { "Sid": "BundleCreate", "Effect": "Allow", "Action": "secretsmanager:CreateSecret",
    "Resource": "arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:ranikun/dev/carelog/enrollment-tls/server-bundle-??????" },
  { "Sid": "BundleWrite", "Effect": "Allow", "Action": "secretsmanager:PutSecretValue",
    "Resource": "<exact ARN of the bundle secret, with its suffix>" },
  { "Sid": "EcrCreateRepos", "Effect": "Allow", "Action": "ecr:CreateRepository",
    "Resource": ["arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy",
                 "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init"] },
  { "Sid": "EcrPush", "Effect": "Allow",
    "Action": ["ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload",
               "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"],
    "Resource": ["arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/carelog/tls-proxy",
                 "arn:aws:ecr:ap-northeast-2:124495093425:repository/ranikun/platform/core-trust-init"] },
  { "Sid": "EcrLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" }
]
```

`CreateSecret` cannot name the ARN before it exists, so its resource uses the `-??????` suffix pattern. `PutSecretValue` is
limited to the exact ARN after creation. Image digests are pinned by Terraform, so no `ecr:PutImageTagMutability` or lifecycle
change is part of this list. ECR repositories are created with immutable tags, scan on push and a lifecycle policy, in a
separate setup step (not in this list).

Not verified against AWS: the `??????` CreateSecret pattern, whether `ecr:PutImage` and the layer-upload actions are the full
set for `docker push`, and the log-group statement for the proxy container.

## 6. Build and publish

1. Get the Core digest from the Core task definition that runs in DEV (`repo@sha256:...`). Tags are refused.
2. `CORE_IMAGE=<digest> CA_BUNDLE=<public CA PEM, ca/root.crt or ca-bundle.pem> SOURCE_SHA=<commit> PROXY_REPO=<ecr>/ranikun/carelog/tls-proxy TRUST_REPO=<ecr>/ranikun/platform/core-trust-init build/build-images.sh`
3. Put the printed digests into the carelog and Core root variables. Run `terraform plan`. Release owns the deploy.

## 7. Rollout and rollback

Rollout, in order:

1. Deploy carelog-be with loopback-only internal endpoints. Old Core claims stay allowed through the app flag during the window.
2. Deploy the proxy image (8443 only) together with the app change above.
3. Roll new Core to `https://<svc>.<ns>:8443` for enrollment and claims. Add the Core SG rule on 8443. Install the trust store (section 4).
4. Verify new Core enrollment and claims over 8443. Verify old Core claims over 8080 still work through the app flag.
5. After the window: remove the Core SG rule on 8080, turn the app flag off, and redeploy.

Rollback, the real path (from review):

1. **Roll Core back to revision `:3` first.** Old Core claims over 8080 use the app flag. Keep the Core SG 8080 rule until this is done.
2. **Then roll Carelog to the pre-sidecar revision.** That is the revision before this proxy existed.
3. **Never push or put in tfvars the image built from `2988980`.** That is the earlier 8080-front design. It conflicts with the
   app's `0.0.0.0:8080` bind (both want task IP:8080) and must not be re-published.

Mixed state is broken. The old proxy (8080 front) binds task IP:8080 and the new app binds `0.0.0.0:8080`. Both cannot run.
The new proxy with an app still on loopback leaves Gateway without a route on 8080. Never run either half against the other.

## 8. Test evidence (this sandbox)

`tests/run-all.sh` (host mode, host nginx 1.24, JDK 17): **97 of 97**.

- `test-entrypoint-negative.sh`: 11 of 11 (wrong SAN, other-SAN cert, expired, swapped fields, CA in leaf slot, key mismatch,
  chain in cert slot, wildcard name, empty name, non-JSON bundle; valid bundle reaches the metadata fetch).
- `test-trust-init.sh`: 10 of 10 in host mode, plus 3 in Docker mode (`DOCKER=1`, stand-in base): 13 of 13 in that mode.
- `test-proxy-host.sh`: 40 of 40. Allowed enrollment PUT and claims GET (query strings with `;//` and `..` pass). Denials
  with JSON bodies: 403 (path variants, `%`, `#`, dot segments, identifiers), 413 over 4 KB, 421 for a mismatched Host.
  No proxy listener on task IP:8080. JDK client: enrollment and claims pass with SAN and hostname verified; default truststore refuses.
- `test-selfca.sh`: 36 of 36. Root and leaf properties, script guards (inside-worktree, non-empty dir, out-of-constraint host,
  reuse), trust-init on the public root, JDK cases (accepted SAN host, sibling hostname refused, sibling in-namespace accepted),
  two-tier outside name refused, and the two recorded anchor-direct findings from section 4.
- Also run in this lane: the proxy template under the pinned `nginx:1.27.5` image (`nginx -t` OK, smoke test on host
  networking). The results matched host nginx.

A real defect found and fixed earlier: on 8443 an encoded internal path (`%69nternal`) passed the allowlist, because `$uri`
is decoded before matching. The path-only deny denies any `%`, so the fix holds.

**Not verified here:**

- **The proxy image was not built.** The sandbox cannot reach `dl-cdn.alpinelinux.org` (DNS error), so the `apk add` of
  `jq=1.8.2-r0` and `openssl=3.3.7-r2` failed. The base image is Alpine 3.21.3. Whether those pins exist on that branch is unknown.
- The Core image and carelog-be were not run. The app loopback check, the claims flag, the app bind and the
  `MANAGEMENT_SERVER_ADDRESS` override are carelog-be's, and nothing here tests them.
- The two-tier chain (section 4) is measured in the test PKI only. The entrypoint change it needs is not implemented.
- Nothing was run against AWS. No deploy, no Terraform, no IAM apply. The IAM snippets are unverified against the account.

## 9. Reviewer checklist

- Confirm carelog-be's loopback check ships before or with this proxy (section 1, sequencing blocker).
- Decide whether to implement the two-tier chain (section 4). Without it the root's name constraints are not a control.
- Confirm `MANAGEMENT_SERVER_ADDRESS` overrides `management.server.address` in carelog-be (section 2).
- Confirm with the Core owner the 5xx retry policy for the idempotent enrollment PUT (section 3).
- Confirm no tunnel or relay container is added to the carelog task (section 2 invariant).
- Confirm the alpine `jq` and `openssl` pins exist on the base's Alpine branch (section 8, not verified).
