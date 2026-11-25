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

## 4. TLS bundle and the DEV CA (self-managed two-tier, `ca/`)

**Decision: self-managed DEV CA, two tiers, not ACM Private CA.** The root is offline. The issuing CA signs the 90-day
leaves on the issuing host. Neither key is in the repo, a task volume, Secrets Manager, or CI.

**Tiers:**

- **Root** (`root.crt`, 730 days): `CA:TRUE, pathlen:1`, `keyUsage keyCertSign,cRLSign`, critical nameConstraints. Its only job is
  to sign the issuing CA. Only `root.crt` goes into trust-init (`ca-bundle.pem`). Core trusts the root, and nothing else.
- **Issuing CA** (`issuing.crt`, 365 days): `CA:TRUE, pathlen:0`, the same critical nameConstraints. Signs the leaves.
  Never trusted by Core directly. It travels in the served chain, and the JDK enforces the constraints on it.
- **Leaf** (90 days): `CA:FALSE`, `EKU serverAuth`, `SAN=TLS_EXPECTED_DNS_SAN`.

**Bundle** (`ranikun/dev/carelog/enrollment-tls/server-bundle`, one Secrets Manager string, JSON):

```json
{ "tls_certificate": "-----BEGIN CERTIFICATE-----\n...leaf...\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\n...issuing CA...\n-----END CERTIFICATE-----\n",
  "tls_private_key": "-----BEGIN PRIVATE KEY-----\n...leaf key...\n-----END PRIVATE KEY-----\n" }
```

The chain is leaf first, then the issuing CA. Only the leaf key is in the bundle. No CA key is ever in it.

**Proxy entrypoint inputs:** `TLS_BUNDLE_JSON` (above), `TLS_EXPECTED_DNS_SAN` (no default), `TLS_ROOT_CA_PEM` (the public
root, an ordinary environment variable, required), and `TWO_TIER_REQUIRED` (default `true`; `false` is a transition switch that
accepts a leaf alone, still verified to the root). The entrypoint refuses: a key in the certificate field, three or more
certificates, a leaf alone while two-tier is required, an issuing CA that is not `CA:TRUE, pathlen:0` with critical
nameConstraints, an expired issuing CA, a chain that does not verify to `TLS_ROOT_CA_PEM` for the expected name, and a root
PEM that holds a key or a non-CA. The name constraints are applied by `openssl verify` as well as by the JDK.

**Scripts:**

- `ca/make-root.sh` (`NAMESPACE`, `SERVICE_HOST`, `OUT_DIR`): creates the root and the issuing CA, both with the same
  constraints (`permitted DNS:.<namespace>` and `DNS:<service host>`, `excluded IP:0.0.0.0/0` and `IP:::/0`). Writes `root.key`,
  `issuing.key` (both 0600), `root.crt`, `issuing.crt`, `ca-bundle.pem` (= root) and `constraints.env`. It refuses an `OUT_DIR`
  inside the worktree and a non-empty one.
- `ca/issue-leaf.sh` (`CA_DIR`, `HOST`, `OUT_DIR`): signs a 90-day leaf with the issuing CA. Refuses a `HOST` outside the
  constraints. Verifies the chain to `root.crt` with the issuing CA as intermediate and the SAN host, then writes `leaf.crt`,
  `leaf.key` (0600) and `bundle.json` (0600, chain = leaf + issuing CA).

**Measured results (JDK 17 HttpClient, trust store = trust-init output from `ca-bundle.pem` only; `test-selfca.sh`):**

| Served chain | Result |
| --- | --- |
| leaf + issuing CA, for the SAN host | accepted (200) |
| same chain, served as the SAN host but leaf names a sibling in the namespace | refused: no SAN matching the host (hostname verification) |
| leaf for `evil.example.org` signed by the issuing CA | **refused**: name constraints (`PKIX path validation failed`) |
| IP-SAN leaf `127.0.0.2` signed by the issuing CA | **refused**: name constraints (excluded IP) |
| leaf for `evil.example.org` issued directly by the root (no issuing CA in the chain) | accepted (200): the root's constraints are not applied to a direct leaf |

So the constraint is a control only when the constrained CA sits in the served chain, which the two-tier layout guarantees.
Name constraints do not stop in-namespace siblings. Hostname verification does.

**External host (`pypi.org`, through the agent CONNECT proxy):** the JDK default truststore and the trust-init store both return
200 with the same body. The derived store only adds one CA (store 120 -> 121, base unchanged). Result: unaffected, measured for this host only.

**Custody:**

- After `make-root.sh`, move `root.key` offline (encrypted medium or password-manager attachment, with one tested copy off the host),
  then delete the host copy (Linux: `shred -u`; macOS: `rm -P`). The root key is needed only to sign a new issuing CA.
- `issuing.key` stays on the issuing host in a restricted directory. It signs every leaf. It is never in the bundle, the repo,
  Secrets Manager or CI. Back it up with the same care as the root key.

**Rotation:**

- **Leaf (every 90 days):** on the issuing host, `CA_DIR=<dir> HOST=<SAN> OUT_DIR=<new empty dir> ca/issue-leaf.sh`. Put
  `bundle.json` as a new version of the bundle secret (`aws secretsmanager put-secret-value --secret-id <ARN> --secret-string file://bundle.json`).
  Force a new proxy deployment, because the entrypoint reads at start. Shred `leaf.key` and `bundle.json` locally. Alert 30 days
  before `notAfter`. The entrypoint fails closed on an expired leaf or an expired issuing CA.
- **Issuing CA (every year):** on the root host, sign a new issuing CA with `root.key` (the script `make-root.sh` writes both; a
  dedicated issuing-only path is a follow-up). Both the old and new issuing CA verify to the same root, so no trust-init change is
  needed. Issue new leaves from the new issuing CA, roll the proxy with the new bundle. Retire the old issuing CA after the last old leaf expires.
- **Root (every 2 years, or on compromise):** `make-root.sh` into a new `OUT_DIR`. Build a trust-init image whose bundle holds both
  roots (`CA_BUNDLE` takes a multi-certificate PEM). Roll Core to that image, then issue from the new chain and roll the proxy.
  Remove the old root after the last old chain expires. On compromise: remove the old root from the bundle at once, roll Core and
  the proxy, and accept the outage.

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

`tests/run-all.sh` (host mode, host nginx 1.24, JDK 17): **114 of 114**.

- `test-entrypoint-negative.sh`: 23 of 23 (wrong SAN, other-SAN cert, expired, swapped fields, CA in leaf slot, key mismatch,
  chain in cert slot, wildcard name, empty name, non-JSON bundle; valid bundle reaches the metadata fetch).
- `test-trust-init.sh`: 10 of 10 in host mode, plus 3 in Docker mode (`DOCKER=1`, stand-in base): 13 of 13 in that mode.
- `test-proxy-host.sh`: 40 of 40. Allowed enrollment PUT and claims GET (query strings with `;//` and `..` pass). Denials
  with JSON bodies: 403 (path variants, `%`, `#`, dot segments, identifiers), 413 over 4 KB, 421 for a mismatched Host.
  No proxy listener on task IP:8080. JDK client: enrollment and claims pass with SAN and hostname verified; default truststore refuses.
- `test-selfca.sh`: 41 of 41. Root, issuing CA and leaf properties, script guards (inside-worktree, non-empty dir, out-of-constraint host,
  reuse), trust-init on the public root, JDK cases (accepted SAN host, sibling hostname refused, sibling in-namespace accepted),
  two-tier outside name refused, the Java name-constraint refusals for the issuing CA, the external host comparison, and the one recorded root-direct finding from section 4.
- Also run in this lane: the proxy template under the pinned `nginx:1.27.5` image (`nginx -t` OK, smoke test on host
  networking). The results matched host nginx.

A real defect found and fixed earlier: on 8443 an encoded internal path (`%69nternal`) passed the allowlist, because `$uri`
is decoded before matching. The path-only deny denies any `%`, so the fix holds.

**Not verified here:**

- **The proxy image was not built.** The sandbox cannot reach `dl-cdn.alpinelinux.org` (DNS error), so the `apk add` of
  `jq=1.8.2-r0` and `openssl=3.3.7-r2` failed. The base image is Alpine 3.21.3. Whether those pins exist on that branch is unknown.
- The Core image and carelog-be were not run. The app loopback check, the claims flag, the app bind and the
  `MANAGEMENT_SERVER_ADDRESS` override are carelog-be's, and nothing here tests them.
- The two-tier chain (section 4) is measured with the test PKI and JDK only. It has not been measured against a real Core image or a real AWS bundle.
- Nothing was run against AWS. No deploy, no Terraform, no IAM apply. The IAM snippets are unverified against the account.

## 9. Reviewer checklist

- Confirm carelog-be's loopback check ships before or with this proxy (section 1, sequencing blocker).
- Confirm `MANAGEMENT_SERVER_ADDRESS` overrides `management.server.address` in carelog-be (section 2).
- Confirm with the Core owner the 5xx retry policy for the idempotent enrollment PUT (section 3).
- Confirm no tunnel or relay container is added to the carelog task (section 2 invariant).
- Confirm the alpine `jq` and `openssl` pins exist on the base's Alpine branch (section 8, not verified).
