# DEV Carelog TLS 전환 롤아웃 (Core enrollment·claims 8443)

> 상태: 문서 초안. 실제 배포·Terraform apply·AWS 검증은 수행하지 않았다. 미검증 항목은 `미검증`으로 표시한다.

## 1. 목적

Core(Finance 연동 DEV)가 Carelog를 호출하는 경로(enrollment PUT, claims GET)를 평문 8080 VPC 직접 접근에서
**Carelog 프라이빗 TLS 리스너(task IP:8443)** 로 옮긴다. 이 과정에서 내부 엔드포인트를 **loopback 피어로만** 허용해
8080 직접 노출을 막는다. 구 Core(rev:3)의 claims 호출은 전환 기간 동안 8080으로 유지한다.

## 2. 구성요소와 고정 SHA

| 구성요소 | 저장소 / 브랜치 | 고정 SHA | 역할 |
|---|---|---|---|
| carelog-be 앱 | carelog-be | `f03f1788b036d203056bf042eed780706375858c` | loopback 필터, 플래그, RDS CA 내장(`c675f4b` 포함 확인) |
| TLS 프록시·trust-init·CA 스크립트 | platform-infra `claude/great-heisenberg-u3i75y-dev-tls-images` | `1ad65fb3ba14f9578572352b0e0d4b9ba4d39466` | 8443 전용 nginx 프록시, 2-tier CA, trust-init |
| Carelog Terraform 후보 | platform-infra | `3d219cae0a79e4a1f661aadd1dae77978d4a2926` (`carelog_core_auth`, `https_enrollment`, `preserve.core_claims_security_group_id`) | 사이드카, 8443 SG, 전환용 claims 규칙 |
| Platform Terraform 후보 | platform-infra | `998874266ad98f3c94ee3ddb3a6f3213d0c2c575` (`dev_dual_auth`, `carelog_*_origin`, `core_truststore`) | Core 환경변수·시크릿·trust-init |

참고: `2988980`은 폐기된 8080 front 설계다. 이 이미지를 사용하지 않는다.

## 3. 플래그·환경변수

| 이름 | 대상 | 기본값 | DEV 설정값 (전환 시작) | 롤백 창 동안 값 |
|---|---|---|---|---|
| `CARELOG_INTERNAL_LOOPBACK_ONLY_ENABLED` | enrollment PUT (`carelog.internal.loopback-only.enabled`) | `false` | `true` | `true` 유지 |
| `CARELOG_INTERNAL_CLAIMS_LOOPBACK_ONLY_ENABLED` | claims GET (`carelog.internal.claims-loopback-only.enabled`) | `false` | `false` (구 Core 8080 호출 허용) | `false` |
| `CARELOG_IDENTITY_ENROLLMENT_ENABLED` | enrollment 활성 | prod 기본 false | `true` | `true` |
| `CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED` | claims 활성 | prod 기본 false | `true` (3d219ca 설정) | `true` |
| `SPRING_PROFILES_ACTIVE` | 프로파일 | - | `prod` | `prod` |
| `CARELOG_FLYWAY_ENABLED` / `SPRING_FLYWAY_ENABLED` | Flyway | - | `false` (3d219ca 설정) | `false` |
| `VALKEY_TLS_ENABLED` | Valkey TLS | 필수 입력 | Platform `REDIS_TLS_ENABLED`와 같은 값 | 같은 값 |
| `server.forward-headers-strategy` | 원격 주소 | (yml) `none` 고정 | `none` | `none` |

- **미구현 (Terraform):** 3d219ca `main.tf`의 `core_auth_environment`에 위 두 loopback 플래그가 없다. 지금은 기본값 `false`이므로 enrollment가 8080에서 VPC 피어에 열려 있다. 적용 전 추가가 필요하다.
- 전제 조건: 플래그가 켜지면 `forward-headers-strategy: none`과 `server.tomcat.remoteip.*` 부재를 기동 시 강제한다. 위반 시 기동 실패한다.

## 4. 사전 조건

### 4.1 DB 마이그레이션 (carelog-be `db/migration`)

| 버전 | 내용 | 조치 |
|---|---|---|
| V3 `backfill_identity_principals` | MANAGER를 platform_accounts로 백필 | DEV DB 적용 여부 확인 |
| V5 `refresh_token_account_id` | refresh_token.account_id 추가·백필 | 적용 여부 확인 |
| V9 `external_account_projection` | users.external_account_id, 수신 receipt 테이블 | 적용 여부 확인 |

- 3d219ca 설정은 `CARELOG_FLYWAY_ENABLED=false`다. 즉 마이그레이션은 자동 실행되지 않는다. 적용 절차(누가, 어떤 순서로)는 **미검증**이며 별도 절차로 정해야 한다.
- V2·V4도 V3 이전에 적용되어야 한다(V2가 platform_accounts 생성, V4 제약).

### 4.2 Secret 목록과 짝맞춤

| Carelog 환경변수 | Platform 대응 | 짝 조건 |
|---|---|---|
| `CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET` (32자 이상) | `dev_dual_auth.carelog_enrollment_secret_arn` → `PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL` | 같은 값 |
| `CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET` (32자 이상) | `dev_dual_auth.product_claims_secret_arn` → `PLATFORM_IDENTITY_PRODUCT_CLAIMS_SERVICE_SECRET` | 같은 값 |
| `TLS_BUNDLE_JSON` (`server_bundle_secret_arn`) | 프록시 전용 | 발급 절차 4.3 |
| `TLS_ROOT_CA_PEM` | 공개 루트 PEM 환경변수 | 루트 CA와 일치 |
| `TLS_EXPECTED_DNS_SAN` | 프록시 환경변수 | Core가 쓰는 origin 호스트와 동일 |
| `GATEWAY_INTERNAL_SECRET` | Gateway 측 | 셋 모두 서로 달라야 함(enrollment, claims, gateway) |
| JWT 서명키 | `jwt_signing_key_secret_arn` (Core 서명, Gateway 검증) | 같은 ARN |

- 모든 secret은 ARN만 Terraform에 넣는다. 평문 값은 거부된다.
- Valkey: Carelog `VALKEY_TLS_ENABLED`와 Platform `REDIS_TLS_ENABLED`는 실제 사용 중인 엔드포인트와 같아야 한다.
- Origin 호스트: 9988742 예시는 `ranikun-carelog-dev-api.REPLACE.internal:8443`, 3d219ca README 규칙은 `dev-carelog.<namespace>:8443`이다. **두 값이 다르면 SAN 불일치로 실패한다.** 서비스 이름(`service_name_override`)을 정하기 전까지 미확정이다.

### 4.3 CA 발급 절차 요약 (self-managed two-tier DEV CA)

1. 오프라인 머신에서 `ca/make-root.sh` 실행 → `root.crt`(730일, pathlen:1), `issuing.crt`(365일, pathlen:0), 둘 다 name constraints 적용.
2. `root.key`는 오프라인 암호화 매체로 옮기고 호스트 사본을 삭제한다. `issuing.key`는 발급 호스트에 제한 권한으로 둔다.
3. 리프: `ca/issue-leaf.sh`로 90일 리프 발급 → `bundle.json`(리프 + 발급 CA, 키는 리프만).
4. Secrets Manager에 `bundle.json` 저장(`server-bundle`), 프록시 재배포로 반영.
5. trust-init에는 `ca-bundle.pem`(루트만)을 넣는다. 발급 CA나 중간 CA가 있으면 빌드가 거부한다.
- 리프 만료 30일 전 알림. 만료 시 프록시 entrypoint가 fail-closed한다.
- 만든 체인은 DEV 테스트 PKI와 JDK 17 클라이언트로 검증했다(129/129). 실제 AWS 번들·Core 이미지 검증은 **미검증**.

### 4.4 IAM boundary (최소 변경)

- 프록시 컨테이너(실행 역할): ECR 이미지 pull(해당 repo), 번들 secret `GetSecretValue`(정확한 ARN). KMS는 CMK일 때만.
- trust-init(Core 실행 역할): ECR pull(core-trust-init repo) 만.
- **태스크 역할: 변경 없음.** 앱 컨테이너 추가 권한 없음.
- 운영자·CI: 번들 secret 생성·쓰기, ECR push만(태스크 역할 아님).
- 미검증: `CreateSecret`의 `??????` 접미사 패턴, `docker push`에 필요한 액션 전체 집합, 프록시 로그 그룹 권한.

### 4.5 이미지 빌드

- **`build/build-images.sh`로만** 빌드한다. `CORE_IMAGE`는 `repo@sha256:<64hex>` 필수(태그 거부), `CA_BUNDLE`은 공개 PEM만, `SOURCE_SHA` 필수.
- 출력된 다이제스트만 Terraform 변수에 고정한다.
- CI의 trust-init은 공개 eclipse-temurin 17 JRE 스탠드인 베이스다. 실제 Core 다이제스트 빌드는 Core 게시 후 별도 실행해야 하며, 배포 전 **필수**다.

## 5. 롤아웃 순서

| 순서 | 대상 | 작업 | 완료 기준 |
|---|---|---|---|
| 1 | carelog-be 앱 + 프록시 | **같은 revision**으로 배포. 앱에 loopback 플래그 `enrollment=true`, `claims=false` | 프록시 healthcheck 통과, 8080 enrollment 외부 403 |
| 2 | Finance | dev_dual_auth 입력 반영 | Finance 기동 |
| 3 | Core (trust-init, 8443 enrollment+claims) | trust-init 추가, origin을 `https://<host>:8443`으로, 8443 SG 규칙 추가 | Core 기동, enrollment 201 |
| 4 | Gateway | Gateway 대상 확인(8080 유지) | Gateway 라우팅 정상 |

- 앱 없이 프록시만 배포하거나 프록시 없이 loopback 플래그만 켜면 **경로가 끊긴다.** 프록시와 앱은 반드시 같은 revision.
- 9988742 validate는 carelog 브랜치 병합 후에만 통과한다.

## 6. 전환 기간

- **8080 claims 유지:** `CARELOG_INTERNAL_CLAIMS_LOOPBACK_ONLY_ENABLED=false` + Core의 `preserve.core_claims_security_group_id` SG 규칙 유지.
- **enrollment는 처음부터 loopback-only:** `CARELOG_INTERNAL_LOOPBACK_ONLY_ENABLED=true`. 구 Core가 enrollment를 8080으로 호출하는 경로는 없다고 본다(Core f9adfd3이 비-loopback http를 거부). **Core rev:3의 동작은 미검증.**
- 검증: `EnrollmentRollbackWindowIntegrationTest`가 (enrollment ON, claims OFF) 조합에서 VPC enrollment 403, VPC claims 404 도달, loopback enrollment 201을 고정한다.

## 7. 전환 종료 절차

1. 신규 Core가 8443 claims만 쓰는지 확인(8080 호출 로그 0건, 기간 미정).
2. 구 Core(rev:3)가 완전히 내려갔음을 확인.
3. `CARELOG_INTERNAL_CLAIMS_LOOPBACK_ONLY_ENABLED=true`로 올리고 배포.
4. `preserve.core_claims_security_group_id`를 `null`로 설정 후 apply → core_claims 규칙 삭제.
5. 3d219ca 주석대로 전환 종료일을 handoff 문서에 기록.

## 8. 롤백 순서

1. **Core를 rev:3으로 먼저** 되돌린다. 이때 claims는 8080 http를 쓰므로 claims 플래그는 `false`, core_claims SG 규칙은 유지해야 한다.
2. 그다음 **Carelog를 사이드카 없는 이전 revision**으로 되돌린다.
3. **`2988980` 이미지는 어떤 경우에도 배포·tfvars에 넣지 않는다.** 앱의 `0.0.0.0:8080` 바인드와 충돌한다.
4. 혼합 상태(구 프록시 + 신 앱, 또는 신 프록시 + loopback 앱)는 Gateway 경로를 끊는다. 한쪽만 되돌리지 않는다.

**즉시 롤백 불가 조건:** 전환 종료(7절 3~4단계) 이후에는 구 Core의 8080 claims가 막힌다. 되돌리려면 먼저 core_claims SG 규칙을 다시 만들고 claims 플래그를 `false`로 내려야 한다.

## 9. 검증 체크리스트

| 항목 | 기대 결과 | 상태 |
|---|---|---|
| 8080 기존 API(Gateway 경로) | 정상 응답 | 미검증 |
| 8080 claims (구 Core, 전환 기간) | 정상 응답 | 미검증 |
| 8080 enrollment (VPC 피어) | 403 | 미검증 (테스트 고정은 됨) |
| 8443 enrollment (Core 경유) | 201 | 미검증 |
| 8443 claims | 정상 응답 | 미검증 |
| Core rev:3 롤백 후 claims | 8080 경로로 정상 (flag false, SG 유지) | 미검증 |
| 프록시 허용 외 경로 | 403 JSON | 테스트 40/40 (호스트 nginx) |
| 호스트 불일치 | 421 | 테스트 통과 (호스트 모드) |

## 10. 알려진 제약

- **task netns 신뢰 경계:** 같은 ECS task의 모든 컨테이너는 127.0.0.1을 공유한다. 같은 task에 신뢰할 수 없는 컨테이너(터널 사이드카 등)를 두면 loopback 보장이 깨진다. 추가 금지를 Terraform에서 강제하지 않는다(리뷰로만 통제).
- **Core 측 5xx 재시도:** enrollment PUT 재시도 시 같은 요청이 두 번 도달할 수 있다. Core 소유자와 확인 필요.
- **MANAGEMENT_SERVER_ADDRESS=127.0.0.1 오버라이드:** 미검증.
- **Alpine 패키지 핀(`jq`, `openssl`):** 베이스 브랜치 존재 미검증. 프록시 이미지 미빌드.
- **CI 스탠드인 베이스:** 실제 Core 다이제스트 검증 전까지 배포 금지.
- **3d219ca README 낡은 문장:** "8080 리스너 없음"은 1ad65fb3 결정과 충돌한다. 1ad65fb3 기준으로 정정 필요.
- **origin 호스트 미확정:** 4.2 참조.
- **DEV 기동 선행 결함:** `/run/rds-ca.pem`은 carelog-be `c675f4b`로 이미지에 내장되어 해결됨(ancestor 확인). 배포 이미지가 이 SHA 이후인지 확인 필요.
