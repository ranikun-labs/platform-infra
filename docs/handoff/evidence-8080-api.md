# Evidence: Carelog 8080 existing-API allowlist, 8443 enrollment, and TLS candidate consistency

Status: review candidate. The allowlist in `candidates/carelog-tls/nginx.conf` is derived from source and tested locally with a stub. It is **not** verified against a running Carelog with real credentials, and it is not approved for deployment.
Sources: carelog-be at `318e1afe` (live `:6` build) and `e1f994c2` (candidate build). Only the enrollment controller and its security configuration differ between them for HTTP mappings. Platform repo: `ranikun-labs/platform-services` (gateway, Core). Live reads: ECS and EC2 describe calls only. No secret values were read.

## 1. Routing facts

- Carelog context path: `server.servlet.context-path: /api/v1` (carelog-be `application.yml`). Every controller path below is prefixed with `/api/v1`.
- Live DEV Gateway (`ranikun-platform-dev-gateway`, platform-services `gateway-app`): route `carelog-be` = `Path=/api/**` → `PLATFORM_GATEWAY_CARELOG_BE_URI = http://ranikun-carelog-dev-api.dev.internal:8080`. Routes ahead of it go to Core: `/api/v1/auth/**`, kakao authorization/exchange, and `/api/v1/auth/carelog/registration`. So carelog's own `/auth/*` endpoints are **not reached** through this gateway.
- The same gateway env `PLATFORM_GATEWAY_CARELOG_RAG_URI` also points at `…:8080`, so `/rag/**` requests reach Carelog too (Carelog has no `/rag` controller).
- Live Core (`ranikun-platform-dev-core`): `PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL = http://ranikun-carelog-dev-api.dev.internal:8080`, `…_ENABLED = true`. Claims call: `GET /api/v1/internal/identity/claims/{accountId}` with `X-Service-Id`/`X-Service-Secret` (names only).
- Core enrollment (`CarelogEnrollmentProperties`): base URI must be **https** unless loopback, with no path. Call: `PUT /api/v1/internal/v1/identity/carelog/enrollments/{accountId}` with `Authorization: Bearer`. Not configured in live Core (`:3` env has no enrollment vars), so this is candidate-only.

## 2. Endpoint inventory (carelog-be `e1f994c2`, identical HTTP surface to `318e1afe` apart from enrollment)

| Method | Path (after `/api/v1`) | Controller | Caller in DEV | 8080 decision |
| --- | --- | --- | --- | --- |
| POST | `/users/customers` | CustomerController | Gateway | allow |
| GET | `/users/customers` | CustomerController | Gateway | allow |
| GET, PATCH | `/users/customers/{publicId}` | CustomerController | Gateway | allow |
| POST, GET | `/customer-events` | CustomerEventController | Gateway | allow |
| GET, PATCH | `/customer-events/{eventId}` | CustomerEventController | Gateway | allow |
| POST | `/customer-events/{eventId}/occur`, `/cancel` | CustomerEventController | Gateway | allow |
| POST | `/relations` | RelationController | Gateway | allow |
| GET | `/relations/{id}` | RelationController | Gateway | allow |
| GET | `/relations/manager`, `/relations/customer/{id}`, `/relations/manager/{id}/customer/{id}` | RelationController | Gateway | allow |
| PATCH | `/relations/{id}/status` | RelationController | Gateway | allow |
| DELETE | `/relations/{id}` | RelationController | Gateway | allow |
| POST, GET | `/relations/{id}/journals` | JournalController | Gateway | allow |
| PUT, GET | `/relations/{id}/journals/{journalId}` | JournalController | Gateway | allow |
| GET | `/relations/{id}/journals/{journalId}/history` | JournalController | Gateway | allow |
| POST, GET | `/journal-templates` | JournalTemplateController | Gateway | allow |
| POST | `/users/managers` | UserController | Gateway (public path) | allow |
| GET | `/users/user-id/{userId}`, `/users/email/{email}` | UserController | Gateway | allow |
| PATCH, DELETE | `/users/{publicId}` | UserController | Gateway | allow |
| GET | `/internal/identity/claims/{accountId}` | InternalIdentityClaimsController | **Core** (8080) | allow (only GET, one segment) |
| GET | `/health` | HealthController | none found (kept for parity) | allow (GET) |
| PUT | `/internal/v1/identity/carelog/enrollments/{accountId}` | EnrollmentController (flag `carelog.identity.enrollment.enabled`) | **Core** (8443 only) | **deny on 8080**, allow on 8443 |
| any | `/auth/**` (login, logout, refresh, oauth kakao) | AuthController | none in DEV (Core owns `/api/v1/auth/**` in the DEV gateway) | deny (open question, see §5) |
| any | `/internal/**` other than the two above | — | none | deny (app `denyAll` also applies) |
| any | `/swagger-ui*`, `/v3/api-docs*` | springdoc | gateway public-path list | deny. Prod profile sets `springdoc.api-docs.enabled=false` and `swagger-ui.enabled=false`, so these are not served in DEV. |
| any | `/` (RootController), `/error` | — | none | deny |
| any | `/rag/**` | — | Gateway route points here too | deny (404 becomes 403) |
| any | `/actuator/**` | — | ECS health check uses `127.0.0.1:8081` (management port), not 8080 | deny |

Method restrictions are enforced with `limit_except`, so, for example, `DELETE /users/customers` is refused even though the path is allowed.

## 3. What nginx.conf now does

- 8080 (task IP): one `location ~` per row above, each with its method list. A request-level refusal (`$request_uri`) runs first for `%2e %2f %3b %5c %00`, `;`, `\`, and `..`. Segment characters are `[A-Za-z0-9._@+~-]`, so `/`, `;` and `%` cannot appear inside an id. Everything else returns 403.
- 8443 (task IP, TLS 1.2/1.3): only `PUT /api/v1/internal/v1/identity/carelog/enrollments/<id>`; body limit 4 KB; everything else 403.
- Both listeners proxy to `127.0.0.1:8080` with `proxy_pass` and no URI part, so the request URI is forwarded unchanged. The app must bind `127.0.0.1` (`SERVER_ADDRESS=127.0.0.1`), otherwise `0.0.0.0:8080` collides with the sidecar on the task IP and the app fails to start.

Why the normalization guard matters: nginx matches the decoded, normalized `$uri`, but forwards the raw request. Tomcat handles `..;` path parameters and encodings differently. The test `tomcat ..; path-param` shows the guard blocks the form that would otherwise reach enrollment through an allowed prefix.

## 4. Test results (local Docker, stub backend)

Command (run from the worktree root; `MSYS_NO_PATHCONV=1` is needed on Git Bash so the mount path is not rewritten):

```sh
docker build -t carelog-dev-tls-candidate:local candidates/carelog-tls
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint sh \
  -v "<worktree>/candidates/carelog-tls/test-proxy.sh:/tmp/test-proxy.sh:ro" \
  carelog-dev-tls-candidate:local /tmp/test-proxy.sh
```

Result: `nginx -t` passed, and the script printed `PASS`. It checked 22 allowed 8080 routes (backend reached: 404 from the stub for GET, 501 for non-GET methods the stub does not implement), 17 denied 8080 variants (403), 6 8443 route checks (enrollment PUT reaches the backend; GET, other paths, `;`, `..` and claims path are 403), and wrong-hostname and untrusted-CA handshakes failing.

Limits: the stub returns 404/501 for all paths, so this shows routing and method handling, not Carelog behaviour. Not tested: the real Carelog responses, Core's JDK client, Fargate `TASK_IPV4` discovery, Gateway/Core end-to-end calls, and an exhaustive path fuzz.

## 5. Open questions for the owner

1. `/auth/**`: confirm that no caller reaches carelog `/auth/*` on 8080. The DEV platform gateway routes them to Core. If the legacy `carelog-gateway` (in carelog-be, not deployed in DEV) were used, the auth endpoints would be needed.
2. `/health` on 8080 has no known caller; keep or remove.
3. Core's 8081 inbound rule on `sg-05f27a8598632c610` has no visible source in the describe output. Not part of this change, but worth checking.
4. Gateway `/rag/**` now gets 403 instead of 404 from carelog. Behaviour change for an unused path; confirm nothing depends on the 404.

## 6. Flyway guard env var

- Spring property `spring.flyway.enabled`. Sources: base `application.yml` sets `true`; prod profile sets `${CARELOG_FLYWAY_ENABLED:false}`.
- Live `:6` has `SPRING_PROFILES_ACTIVE=prod` and `CARELOG_FLYWAY_ENABLED=false`. It has **no** `SPRING_FLYWAY_ENABLED`.
- Release workflow guard (`platform-infra` `.github/workflows/dev-ecs-release.yml`, pinned `fdeb228` in carelog-be's caller): the active container must contain exactly one `SPRING_FLYWAY_ENABLED` env entry with value `false` and no secret of that name. Without it the deploy is blocked.
- **Recommendation:** add `{"name":"SPRING_FLYWAY_ENABLED","value":"false"}` to the app container's `environment` in the candidate task definition, and keep `CARELOG_FLYWAY_ENABLED=false`. Spring resolves both to `false`, so there is no behaviour change, which I checked by reading the property sources only, not by running the app. Do not add it as a secret.

## 7. Candidate and Terraform consistency (no Terraform was edited)

| Item | Live `:6` | Candidate (`task-fragments.json`, `carelog.tfvars.example`) | Status |
| --- | --- | --- | --- |
| Proxy image | — | placeholder | Not yet set. Needs digest-pinned private ECR image. |
| Proxy ports | — | 8080 and 8443 in `portMappings` | Matches `nginx.conf` listens. |
| Proxy volume and mount | — | `carelog-tls` → `/run/carelog-tls` (rw) | Matches `proxy-entrypoint.sh` and nginx `ssl_certificate` paths. |
| Proxy secrets | — | `TLS_CERT_PEM`, `TLS_KEY_PEM` (ARNs placeholder) | Matches entrypoint. ARN form (plain vs `:key::`) unverified. |
| Proxy `logConfiguration` | — | **missing** in fragment and tfvars example | Mismatch. The rollout doc template includes awslogs `tls-proxy` prefix. Add it. |
| Proxy `healthCheck` | — | missing | Open. The proxy has no health check, so ECS sees the proxy as healthy while the app is not ready (502 window). |
| App `SERVER_ADDRESS` | unset (binds 0.0.0.0) | `127.0.0.1` in fragment and tfvars | Consistent and required. |
| App `CARELOG_IDENTITY_ENROLLMENT_ENABLED` | absent | `true` in tfvars example, **absent in fragment** | Mismatch between the two candidate files. Enrollment controller stays unregistered (8443 returns 404) if only the fragment is used. |
| App `CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET` | absent | injected by Terraform from `enrollment_secret_arn` | Secret `ranikun/dev/carelog/enrollment-service` exists (1 version, no CMK, no rotation). Value format not checked. |
| App `SPRING_FLYWAY_ENABLED` | absent | absent | Add (§6). |
| App `portMappings` | 8080 | `[]` in fragment and `app_port_mappings = []` in tfvars | Consistent only if tfvars sets `app_port_mappings = []`; the module default is 8080. |
| App `dependsOn` proxy | — | none | Acceptable; the app does not need the proxy to start. |
| SG 8080 ingress from Gateway and Core | `sg-0378d994a87b68492`: 8080 from gateway SG and from Core SG (`core_claims`) | unchanged | Matches. |
| SG 8443 ingress from Core | not present | planned `core_enrollment_tls` from `enrollment_core_security_group_id` | Matches the planned rule. Core SG `sg-05f27a8598632c610` has egress to 0.0.0.0/0, so no Core-side change is needed. |
| SG 8081 (management) | not in SG ingress | not planned | Good: actuator is not reachable from Gateway or Core, though it binds 0.0.0.0:8081 inside the task. |

## 8. Other notes

- Core's enrollment client refuses a non-loopback `http://` base URL, so the candidate must use an `https://` name that matches the sidecar certificate SAN. The current candidate test uses `carelog.test`; the real DNS name is not decided.
- `test-proxy.sh` is tracked with git mode `100644` (`git ls-files -s`), but it is executable on disk. The README runs it through `sh`, so this does not block it.
- The DEV `:6` task definition has 6 secrets (claims service secret, JWT, DB user and password, Redis password, gateway internal secret). None of them are TLS or enrollment secrets.

## 9. 2026-11-24 rerun against the rebuilt proxy image and corrections

Command (same as §4; image rebuilt from the current `candidates/carelog-tls` tree, digest of the local build not pinned):

```sh
docker build -t carelog-dev-tls-candidate:local candidates/carelog-tls
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint sh \
  -v "<worktree>/candidates/carelog-tls/test-proxy.sh:/tmp/test-proxy.sh:ro" \
  carelog-dev-tls-candidate:local /tmp/test-proxy.sh
```

Result: exit 0, `PASS: 8080 allowlist, 8443 enrollment-only, method, encoding and TLS checks`, 65 `ok` lines, 0 `FAIL`. Output saved outside the repo (private scratch).

Failure found and fixed in this round:
- `//api/v1/users/customers` on 8080 returned 404 (reached an allowed location). Cause: nginx `merge_slashes` (default on) normalized the double slash before location matching, and the unnormalized request was forwarded to Tomcat. Fix: `merge_slashes off;` in both server blocks of `nginx.conf`. The double-slash case on 8080 and the 8443 enrollment path now return 403.

Cases added to `test-proxy.sh` (all pass):
- 8080: HEAD on a GET route reaches the backend (nginx `limit_except GET` also allows HEAD); OPTIONS on a collection and on the enrollment path is 403; uppercase prefix, trailing slash, double slash, `%2F` in an id segment, and a `/.` suffix are 403; a foreign `Host:` header does **not** change routing (documented: the 8080 listener is only reachable from Gateway and Core security groups, so app authentication is the boundary).
- 8443: HEAD, OPTIONS, PATCH and `/` are 403; a 4000-byte PUT reaches the backend; a 5000-byte PUT returns 413 (`client_max_body_size 4k`).
- ECS healthCheck: `kill -0 $(cat /run/nginx.pid)` run in the image: exit 1 before nginx starts, 0 while running, 1 after `nginx -s stop`. `/run/nginx.pid` is the path in the image (`/var/run` is a symlink to `../run`).

Not covered: the stub returns 404/501 for every path, so this still shows routing and method handling only. Real Carelog responses and Tomcat's treatment of encoded forms remain untested (no JDK on this host).

## 10. Task definition configuration checks (2026-11-24)

- `environments/dev/carelog`: `terraform fmt -check -recursive` (exit 0 after formatting the test file), `init -backend=false`, `validate` (valid), `test` (4 passed, 0 failed). New runs: `enrollment_candidate_app_env_and_port_mappings` (app `portMappings` is an explicit `[]`, app env includes `CARELOG_IDENTITY_ENROLLMENT_ENABLED=true`, `SPRING_FLYWAY_ENABLED=false`, `SERVER_ADDRESS=127.0.0.1`, no secret-named keys) and `unset_app_port_mappings_is_null_module_default` (documents that a null value makes the module emit containerPort 8080 for the app).
- `carelog.tfvars.example` parses with the merged required inputs (scratch copy, `terraform console`): `app_port_mappings` = `[]`, app env as above, proxy `healthCheck.command` = `["CMD-SHELL", "kill -0 $(cat /run/nginx.pid) || exit 1"]`, `logConfiguration` stream prefix `tls-proxy`.
- Module path: `modules/ecs-service/main.tf` line 123 (`container_definitions = jsonencode(concat([...], var.additional_containers))`) passes candidate containers through raw, so the proxy's `logConfiguration` and `healthCheck` must be in the candidate input (done). The awslogs group `/ecs/ranikun-carelog-dev-api` equals the module's `aws_cloudwatch_log_group.service` name (`"/ecs/${var.name}"`), and the execution role already allows `logs:CreateLogStream`/`PutLogEvents` on it. No module change needed.
- The TLS secret references and certificate/key/CA ARNs were not changed.
