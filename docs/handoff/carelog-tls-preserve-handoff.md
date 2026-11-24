# Carelog DEV 사설 TLS 후보 · 기존 구성 보존 검토 인계

상태: **검토용 브랜치. plan까지만 확인했다. apply·ECS 서비스 갱신·Task 정의 등록은 하지 않았다.**
기준 커밋: `74b4c5e79036f32e508a2f30b8420fa9e6302c6a` (TLS 후보). 이 브랜치는 그 위에 보존 변경과 인계 자료만 얹는다.
대상: 계정 124495093425, ap-northeast-2, 클러스터 `dev-shared`. 실행 프로필 `ranikun-admin`(읽기·plan만).

이 문서에는 state, `tfvars`, plan 원문, Secret 값, 개인키, 환경변수 값이 없다. 리소스 주소와 액션, 변수 이름, 비밀이 아닌 식별자만 있다.

## 1. 무엇을 바꿨나

기존 DEV 구성이 `main` 코드와 달라서 plan이 라이브 설정을 지우려 했다. 두 보존 패치(Carelog, Platform)를 대조해 `modules/ecs-service`를 하나로 합쳤다. 두 사본의 모듈은 의미상 같았고, 서식(CRLF)과 `additional_containers` 타입 표기만 달랐다. 합친 결과는 Platform 쪽 표기(LF, `any`)를 따른다.

| 파일 | 변경 |
| --- | --- |
| `modules/ecs-service/variables.tf` | 보존 입력 5개 추가: `assign_public_ip`, `execution_permissions_boundary_arn`, `task_permissions_boundary_arn`, `assume_role_source_conditions`, `service_discovery_custom_health_check`. 기본값은 모두 기존 동작과 같다 |
| `modules/ecs-service/main.tf` | 위 입력 반영. 빈 `mountPoints`·`dependsOn`은 값이 있을 때만 넣도록 조건부로 변경(74b4c5e는 항상 넣었다) |
| `environments/dev/carelog/{main,variables}.tf` | 서비스 이름을 배포된 `ranikun-carelog-dev-api`로 고정. `preserve` 입력, 기존 `core_claims` 규칙, `core_security_group_id`, 서비스 볼륨(`runtime.additional_volume_names`·`app_mount_points`) 추가 |
| `environments/dev/carelog/tests/contract.tftest.hcl` | 새 필수 변수 반영, `core_claims` 보존 검증 추가 |
| `environments/dev/platform/{services,ingress,variables}.tf` | `gateway_preserve`·`core_preserve`, `gateway_additional_containers`(cloudflared 2개), `gateway_public_alb_enabled`(기본 true) 추가. ALB 리소스는 이 값으로 게이트 |
| `environments/dev/platform/tests/contract.tftest.hcl` | ALB 참조를 `[0]` 인덱스로 수정 |

겹친 변경(두 패치가 같은 곳을 고친 부분)은 모듈 두 파일뿐이다. 환경 파일은 서로 겹치지 않는다.
사용자가 이미 갖고 있던 `.terraform.lock.hcl` 수정 두 건은 이 브랜치에 포함하지 않았다.

## 2. 원인: Carelog `+9 / −10`

- `main` 코드가 이름을 `dev-carelog`로 하드코딩한다. 배포된 state는 `ranikun-carelog-dev-api`다.
- 이름이 바뀌면 SG, IAM role 2개, 로그 그룹, Cloud Map 서비스, Task family, ECS 서비스가 전부 교체된다(9개 재생성).
- 열 번째 삭제는 `aws_vpc_security_group_ingress_rule.core_claims`다. state에는 있지만 이 저장소의 어떤 커밋에도 선언이 없다.
- 배포에 쓰인 정확한 코드는 저장소에서 찾지 못했다. 위 변경은 state와 라이브 값으로 복원한 것이므로 **추정**이다.

## 3. plan을 어디까지 확인했나

모두 이 브랜치 코드로, 원격 S3 state 대상 `plan -lock=false`를 실행했다. 입력은 라이브 서비스의 현재 revision(Carelog `:6`, Core·Gateway `:3`)에서 복원한 비공개 파일이다.

| 루트 | 입력 | 결과 | 주소별 액션 |
| --- | --- | --- | --- |
| carelog | 보존 입력 | `+1 / ~0 / −1` | `module.service.aws_ecs_task_definition.baseline` create/delete |
| carelog | 보존 입력 + TLS | `+2 / ~1 / −1` | 위 + `aws_vpc_security_group_ingress_rule.core_enrollment_tls[0]` create, `module.service.aws_iam_role_policy.execution` update |
| platform | 보존 입력(ALB off) | `+2 / ~0 / −2` | `module.core`·`module.gateway`의 `aws_ecs_task_definition.baseline` create/delete |
| platform | 보존 입력 + TLS | `+2 / ~1 / −2` | 위 + `module.core.aws_iam_role_policy.execution` update |

보존 항목(서비스, IAM role·boundary·trust 조건, Cloud Map, SG, 로그 그룹, 시크릿 참조, 헬스체크, gateway의 cloudflared 컨테이너)은 모두 no-op이다.
Task 정의 교체는 "새 revision 등록"이다. `skip_destroy=true`라 기존 revision은 deregister되지 않고, 서비스는 `ignore_changes`라 새 revision을 쓰지 않는다.

비교용 이전 결과: 원본 `main`은 Carelog `+9 / −10`, Platform `+13 / ~7 / −4`(ALB 포함 20개 주소 변경)였다. 이름과 `core_claims`만 맞춘 Carelog 기준은 `+1 / ~4 / −1`이었다.

Carelog 보존 plan의 새 Task 정의는 라이브 `:6`과 이미지, 환경변수, 시크릿 참조, `startPeriod` 300이 같다. 남는 차이는 AWS 정규화 값(`hostPort`, 기본값 필드, 키 순서)뿐이다. 등록 후 다시 plan해서 확인해야 한다.

### 검증 명령 결과

| 명령 | 결과 |
| --- | --- |
| `terraform fmt -recursive -check` | 통과 |
| `terraform validate` (carelog, platform, finance, shared) | 모두 통과 |
| `terraform test` (carelog 2, platform 2, finance 1, shared 2) | 모두 통과 |

## 4. 확인하지 못한 것 · 남은 입력

TLS 입력의 실제 값이 AWS에 없어서 TLS plan은 구조 확인용이다(가짜 값 사용).

| 항목 | 상태 |
| --- | --- |
| 프록시·init용 ECR 리포지토리와 digest | 없음 |
| 서버 인증서·개인키 시크릿(`TLS_CERT_PEM`, `TLS_KEY_PEM`) | 없음 |
| Core용 CA 시크릿(`CARELOG_CA_PEM`) | 없음 |
| ACM 인증서, ACM PCA (ap-northeast-2) | 0건 |
| Platform `certificate_arn` | 복구 불가(ALB가 라이브에 없음) |
| Platform `alb_ingress_cidrs` | 출처 없음 |
| 승인된 새 Carelog 이미지 | digest `sha256:2630045e50b01879b0d3462fcd38509b9255131af52928e3a04878c6ade11d39`가 ECR `ranikun/carelog/api`에 존재(2026-11-23 17:13 KST). **승인 기록은 AWS와 저장소에서 찾지 못함** |
| 현재 `:6` 이미지 `sha256:7dd7b858abb0fe701d2ac3a5c6cd25bfedea7efdc1a7f47fdc28362961561e54` | 존재. enrollment 기능 지원 여부 미확인 |
| enrollment 시크릿 | 존재(`ranikun/dev/carelog/enrollment-service`). `:key::` 접미사 필요 여부 미확인 |
| Platform 원격 state와 로컬 사본이 같은지 | 미확인(plan은 원격 기준) |
| 보호된 실제 `terraform.tfvars` | 접근하지 않음. 라이브 값으로 재구성 |

복원에 쓴 입력 변수 이름(값은 비공개):
- carelog: `region`, `aws_account_id`, `shared{vpc_id,private_subnet_ids,cluster_arn,namespace_id}`, `gateway_security_group_id`, `core_security_group_id`, `runtime{image,ecr_repository_arn,container_port,cpu,memory,environment,secrets,execution_secret_arns,execution_kms_key_arns,health_check,log_retention_days,additional_volume_names,app_mount_points}`, `preserve{…}`, `enrollment_secret_arn`, `enrollment_core_security_group_id`, `enrollment_tls_candidate`, `tags`
- platform: `aws_region`, `aws_account_id`, `name_prefix`, `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `cluster_arn`, `namespace_id`, `namespace_name`, `certificate_arn`, `alb_ingress_cidrs`, `gateway_first_task_definition_arn`, `core_first_task_definition_arn`, `gateway_public_alb_enabled`, `gateway_additional_containers`, `gateway_preserve`, `core_preserve`, `enrollment_tls_candidate`, `enrollment_secret_arn`, `tags`

## 5. 적용 전에 풀어야 할 문제

1. **IAM boundary.** Core·Carelog execution role의 boundary(`dev-boundary/…-execution`)는 TLS용 ECR·시크릿(enrollment, 인증서, 키, CA)을 허용하지 않는다. IAM 시뮬레이션에서 Core의 enrollment 시크릿이 implicit deny였다. boundary는 이 저장소 밖에서 관리되는 것으로 보인다.
2. **TLS 후보 Task 정의의 기반 revision.** 후보(74b4c5e)는 Terraform baseline `:1`에서 파생돼 `:6`의 `config-tree` 볼륨, `GATEWAY_INTERNAL_SECRET`, product-claims 참조, `startPeriod` 300을 잃는다. 서비스에 올릴 revision은 `:6`을 기반으로 병합해서 등록해야 한다(`carelog-tls-ecs-rollout-rollback.md`).
3. **Flyway 가드.** 릴리스 워크플로는 `SPRING_FLYWAY_ENABLED=false`가 있어야 진행한다. `:6`에는 `CARELOG_FLYWAY_ENABLED`만 있다. 추가하면 동작이 바뀌므로 소유자 결정이 필요하다.
4. **프록시 8080 허용 경로.** `candidates/carelog-tls/README.md`가 목록이 불완전하고 배포 승인 전이라고 명시한다. 외부 검토의 APPROVE 없이는 올리지 않는다.
5. **Gateway.** `cloudflared-quick`(필수 아님)은 임시 터널로 gateway를 외부에 노출한다. 라이브 그대로 보존했으며 보안 검토가 필요하다. ALB를 켤지(`gateway_public_alb_enabled`)도 결정해야 한다. 라이브에는 ALB가 없다.
6. **과권한 후보.** 라이브 Core 실행 정책은 Core가 쓰지 않는 gateway-internal 시크릿 읽기를 포함한다. 보존했다.
7. **네트워크.** 서브넷에 NAT·VPC endpoint가 없다. `assign_public_ip=false`로 바꾸면 ECR pull이 실패할 가능성이 크다. 보존 입력은 라이브대로 true다.
8. **서비스 registry.** Cloud Map 서비스를 교체하는 plan이 나오면 service_registries 변경을 API가 받아들일지 apply 전에는 알 수 없다. 보존 plan에서는 교체가 없다.

## 6. 외부 검토 요청 범위

이 브랜치의 diff와 위 표를 검토해 달라.
- 모듈 변경이 기존 동작을 바꾸지 않는지(기본값 경로), finance·shared 루트 영향.
- 이름·`core_claims` 복원이 배포 상태와 맞는지.
- boundary·trust 조건·공개 IP 보존이 보안상 타당한지, 보존 대신 개선해야 하는지.
- TLS Task 정의 병합 방식(`:6` 기반)과 반영·롤백 순서.
- 위 5번 항목의 gateway 노출.
APPROVE 또는 지적 사항과 검토한 정확한 SHA를 알려 달라. 이 브랜치는 apply하지 않는다.

## 7. Mac mini에서 이어갈 첫 작업

`git fetch origin && git switch codex/carelog-dev-tls-preserve-review`로 이 브랜치를 받은 뒤, **plan을 비공개 입력 없이 재현할 수 있는지부터 확인**한다.

1. `terraform fmt -recursive -check`와 `terraform validate`, `terraform test`를 네 루트(carelog, platform, finance, shared)에서 실행한다(`init -backend=false`). 이 단계는 AWS 자격 증명이 필요 없다.
2. 통과하면 외부 GPT 검토 결과를 받아 5번 항목의 결정(boundary 수정 권한자, Flyway 가드, ALB, gateway 노출)을 정리한다.
3. 실제 TLS 값(프록시 이미지 digest, 인증서·키·CA 시크릿)이 생기면 `scripts/plan-summary.sh`로 비밀값 없는 plan 요약을 만들어 이 문서의 3번 표를 갱신한다.

state·`tfvars`·plan 원문은 저장소에 두지 않는다. 입력 파일은 Mac mini에서 운영자 경로로 다시 만들어야 한다(라이브 revision에서 복원하는 방법은 4번 변수 목록 참고).

## 8. 2026-11-24 갱신: 입력 대조와 구현 준비

기준 코드는 41320c4이고 Terraform 코드는 바꾸지 않았다. 실행 프로필은 `ranikun-admin`이다(읽기·plan만). apply, ECS 갱신, AWS 쓰기는 하지 않았다.

### 8.1 현재 AWS와 복원 입력 대조
- Platform Core·Gateway는 `:3`, Carelog는 `:6`이 라이브이며 모두 desired 0이다. 이미지 digest, IAM boundary·trust 조건, Cloud Map, 보안 그룹, 공개 IP는 복원 입력과 일치한다. state 사본과 원격의 serial·lineage도 같다.
- 입력이 같아 plan은 다시 만들었지만 결과가 같다. baseline Carelog `+1 / −1`, Platform `+2 / −2`. TLS Carelog `+2 / ~1 / −1`, Platform `+2 / ~1 / −2`. 삭제는 모두 Task 정의 교체(`skip_destroy=true`)다.
- 실제 TLS 값(프록시·trust-init 이미지 digest, 인증서·키·CA Secret, ACM)은 AWS에 아직 없어 TLS plan은 계속 자리표시자 값이다.

### 8.2 Carelog 이미지 `sha256:2630045e…` 근거 (상세: `evidence-carelog-image.md`)
- **발행 성공**: carelog-be PR #61 머지 커밋 `5d6aa88c…`, run 45136354872(release/publish success, deploy skipped). ECR 태그 `5d6aa88c…-45136354872-1`(IMMUTABLE)의 digest가 같다.
- **배포 승인**: 근거 없음. deploy가 skipped이고 해당 SHA의 deployment가 없으며 PR 리뷰 0건이다.
- 후보에는 마이그레이션 V9(스키마 변경)가 있다. DEV 배포 가드가 Flyway를 막으므로 DEV DB에 V9가 먼저 있어야 한다. DB 상태는 확인하지 않았다. 이미지 롤백은 DDL을 되돌리지 못한다.

### 8.3 구현 준비 (모두 로컬 빌드·테스트, 푸시·적용 없음)
- 프록시·trust-init Dockerfile과 스크립트 보강, `nginx.conf` 경로 허용 목록 완성(`evidence-8080-api.md`), `test-proxy.sh` 허용·거부 검증(통과), trust-init로 JDK 클라이언트 TLS 검증(통과). 스텁 백엔드라서 실제 Carelog·Core·Fargate 검증은 안 했다.
- 발행 워크플로 초안은 `.github/workflows-draft/`에 있어 동작하지 않는다(`prep-images.md`).
- AWS 변경 목록은 `prep-aws-changes.md`, 인증서·키·CA 보관은 `prep-cert-secrets.md`(Secrets Manager 3개, ACM·ACM PCA는 DEV에 부적합), boundary 변경안은 `prep-iam-boundary.md`다. 비용은 2026-11-24 가정치이며 가격 페이지로 확인하지 않았다.
- 시뮬레이션에서 Carelog·Core 실행 역할은 TLS용 Secret·ECR과 enrollment Secret에 implicitDeny다. enrollment Secret 누락은 TLS 이전부터의 문제다.

### 8.4 적용 전에 고칠 불일치
1. `task-fragments.json`의 앱 env에 `CARELOG_IDENTITY_ENROLLMENT_ENABLED=true`가 없다(없으면 8443이 404).
2. 프록시 컨테이너에 `logConfiguration`과 명시적 `healthCheck`가 없다(ECS는 Dockerfile HEALTHCHECK를 쓰지 않는다).
3. 앱 `SPRING_FLYWAY_ENABLED=false`를 추가한다(현재는 `CARELOG_FLYWAY_ENABLED=false`뿐, 값은 같다).
4. 앱 `portMappings`는 tfvars에서 `[]`로 맞춰야 한다.
5. 서버 인증서 SAN에 Cloud Map 이름이 있어야 한다. CA 이중 번들 교체는 테스트하지 않았다.
6. 프록시 도입으로 `/rag/**`는 404 대신 403이 된다.

### 8.5 아직 없는 참조 (AWS 쓰기 필요)
ECR repo `ranikun/carelog/tls-proxy`, `ranikun/platform/core-trust-init`와 digest, Secret `ranikun/dev/carelog/enrollment-tls/{server-cert,server-key,ca-cert}`의 ARN, boundary v4와 담당자 승인. 이것이 생기기 전에는 plan을 의미 있게 다시 만들 수 없다.

### 8.6 알 수 없는 것
`:5`·`:6`을 누가 등록했는지, DEV DB의 V9 적용 여부, enrollment Secret ARN의 `:key::` 접미사 형식과 Core·Carelog의 Secret 공유 여부, Core 보안 그룹의 8081 인바운드 출처.

## 9. 2026-11-24 2차: 1-secret 안 반영과 Task 설정 반영

기준은 ef9a3e1이다. AWS 쓰기는 하지 않았다(승인 대기). 새 plan은 만들지 않았다(실제 이미지·Secret 참조가 없다).

### 9.1 Secret 3개 → 1개 (상세: `prep-cert-secrets.md`, `prep-aws-changes.md`, `prep-iam-boundary.md`)
- **1개 안**: 서버 인증서·키를 Secret 하나(JSON `tls_certificate`, `tls_private_key`)에 두고 프록시는 `TLS_BUNDLE_JSON` 하나로 읽는다. CA 공개 인증서는 Core trust-init 이미지에 빌드 인자로 넣는다(`CA_BUNDLE_SRC`, 비밀 아님). 가입용 Bearer Secret은 그대로다.
- **비용(서울, 2026-11-24 Price List API)**: Secrets Manager $0.40/secret-월 + $0.05/1만 호출, ECR $0.10/GB-월, CMK $1.00/키-월. 3개 안 월 약 $1.33, 1개 안 월 약 $0.52(CMK 없이). 차이는 월 $1 미만이라 비용이 결정 요인이 아니다.
- **권한**: Core는 TLS Secret을 읽지 않는다(서버 키 읽기 거부 유지). Carelog는 번들과 enrollment만 읽는다. boundary v4 시뮬레이션 12건 중 12건이 기대와 일치했다. 변경은 Carelog와 Core 실행 boundary 두 곳이다.
- **교체·갱신**: 인증서 갱신은 `PutSecretValue` 한 번 + 새 배포. 3개 안은 인증서와 키가 다른 버전에서 읽혀 짝이 어긋날 수 있었고(ECS는 `valueFrom`을 따로 읽음) 1개 안은 읽기 한 번이라 어긋날 수 없다. CA 교체는 이미지 재빌드와 Core 롤아웃이 필요하다(2-CA 번들 테스트함). CA를 Secret으로 둬야 하면 3개 안으로 돌아가며 프록시 엔트리포인트는 두 방식을 모두 지원한다.
- **롤백**: 이전 Secret 버전 또는 이전 Task 정의 revision(Carelog `:6`, Core·Gateway `:3`).
- 반영한 파일: `proxy-entrypoint.sh`, `trust-init.sh`(다중 CA 가져오기, CA:TRUE 검사), `Dockerfile.trust`, `task-fragments.json`, `carelog.tfvars.example`, `platform.tfvars.example`, 초안 워크플로.

### 9.2 Carelog Task 설정 반영
- `CARELOG_IDENTITY_ENROLLMENT_ENABLED=true`, `SPRING_FLYWAY_ENABLED=false`, 프록시 `logConfiguration`·`healthCheck`를 후보 입력에 넣었다. `app_port_mappings=[]`(앱 포트 매핑 없음)을 확인했다. 모듈 변경은 필요 없다.
- `nginx.conf`에 `merge_slashes off`를 넣었다. `//api/...` 경로가 허용 위치로 통과하는 문제를 테스트가 찾았다.
- Flyway: `SPRING_FLYWAY_ENABLED`가 `spring.flyway.enabled`에 바인딩되어 yml보다 우선하고, 릴리스 가드(`dev-ecs-release.yml` 131~135행)는 이 변수만 읽는다(`evidence-flyway-v9.md`). 라이브 입력에 `CARELOG_FLYWAY_ENABLED=false`와 `SPRING_PROFILES_ACTIVE=prod`가 있어야 한다.
- **DEV DB의 V9: 알 수 없음.** 로그·RDS 메타데이터·GitHub run에 마이그레이션 흔적이 없다. 미적용으로 보고 계획한다. 확정하려면 DEV VPC 안에서 읽기 전용 계정으로 `SELECT version, success FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 5;`를 실행해야 한다(Secret과 접속 경로 필요, 하지 않았다).

### 9.3 테스트 결과 (로컬, 합친 코드 기준)
| 항목 | 결과 |
|---|---|
| `test-proxy.sh` (프록시 이미지 재빌드) | PASS, 65건 |
| 프록시 인증서·키 짝 검사(1개 안·3개 안, 어긋남·키 없음·무관한 키·입력 없음) | 7/7 PASS |
| trust-init + Core 이미지 JDK 클라이언트 (CA 1개·2개, 기본 CA 유지, 잘못된 이름 거부, init 없으면 거부) | 7/7 PASS, 저장소 항목 117→118(1 CA)·117→119(2 CA) |
| Terraform fmt / validate / test: carelog, platform, finance, shared | 전부 통과 (4, 2, 1, 2건) |
| hadolint, shellcheck, actionlint | 통과 |

위 둘째·셋째 테스트 스크립트는 비공개 경로와 런타임에 만든 일회용 인증서를 쓰므로 저장소에 넣지 않았다. 재현이 필요하면 `prep-cert-secrets.md`의 테스트 설명을 따라 다시 작성한다.
검증하지 못한 것: 실제 ECS Secret 주입, Fargate 메타데이터 IP, 실제 CA 체인(ECDSA), Spring Boot 앱 테스트(JDK 없음), 프록시 healthCheck의 리스너 확인(nginx 마스터 프로세스만 확인).

### 9.4 AWS 쓰기 승인 요청 (`prep-aws-changes.md` 2번 표, 아직 실행하지 않음)
ECR repo 2개, Secret 1개, boundary v4 두 곳, OIDC 발행 역할, GitHub environment, 배포 역할의 Terraform apply, 선택 사항 CMK. 월 비용 약 $0.52(CMK 시 약 $1.52). 입력이 모두 필요하다: 두 repo의 이미지 digest, 번들 Secret ARN(접미사 포함), 공개 CA 번들 파일(`candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem`), boundary 담당자.

### 9.5 열린 질문
CA 오프라인 서명 담당, CA 이미지 포함에 대한 보안 수락 여부, CMK 요구 여부, boundary 담당자, DEV DB V9 적용 여부, 새 Carelog 이미지의 DEV 배포 승인자.

## 10. 외부 검토 반영 (기준 65ef0e7): 수정·검증 요약과 재현 명령

AWS 쓰기와 ECS 적용은 하지 않았다. 새 plan도 만들지 않았다(실제 이미지·Secret 참조 없음). 단일 Secret 설계를 유지했다.

### 10.1 지적별 반영
| 지적 | 반영 | 근거 |
|---|---|---|
| ① Core JVM 옵션·활성 프로필·기존 CA 보존, Core/trust-init 이미지 일치 | 라이브 Core `:3`은 `JAVA_TOOL_OPTIONS`와 `SPRING_PROFILES_ACTIVE`를 설정하지 않는다. 후보가 `SPRING_PROFILES_ACTIVE=dev`를 추가하던 것을 제거했다. `environments/dev/platform/core_env.tf`가 라이브 키를 보존하고(다른 값이면 plan 실패), `JAVA_TOOL_OPTIONS`는 병합한다. trust-init은 Core 이미지의 `cacerts`를 복사한 뒤 CA만 추가한다(기존 118개 별칭 모두 유지, 118→119·120). `Dockerfile.trust`가 `ARG CORE_IMAGE`와 OCI 라벨로 기반 digest를 기록하고 `tests/check-core-digest.sh`와 워크플로가 Core Task의 digest와 일치를 검사한다. | `prep-cert-secrets.md`, `tests/` |
| ② 단일 번들 배포·이전 Secret 버전 복구 | `prep-cert-secrets.md` 11번(만들기 → 값 넣기 → 맨 ARN 참조 → 새 배포; 복구는 `update-secret-version-stage`로 `AWSCURRENT` 이동 + Task revision 롤백), `carelog-tls-ecs-rollout-rollback.md`를 단일 번들 기준으로 재작성. 가입용 Bearer Secret은 모든 단계에서 쓰기·삭제·교체·복원·버전 이동·읽기를 하지 않으며, 복구 담당 정책에 명시적 Deny가 있다. | 시뮬레이션 27건 |
| ③ 실제 8080·8443 리스너 헬스 체크 | 프록시 헬스 체크가 8080, 8443 TLS 핸드셰이크(서버 인증서와 파일 일치), 앱 관리 liveness를 확인한다. 새 `/healthz`는 `127.0.0.1:9180`에서만 열린다. `startPeriod` 300초(앱 기동 161~179초 관측). Dockerfile, Task fragment, tfvars 예시, 테스트의 명령이 동일하다. | `evidence-8080-api.md` 11번 |
| ④ 잘못된 PEM 즉시 실패, Secret 주입·권한 테스트 | 프록시: JSON 객체·두 키·단일 leaf·키/인증서 필드 뒤바뀜·`CA:FALSE`·만료·SAN(변수 `TLS_EXPECTED_DNS_SAN`)·짝 일치를 검사하고 값은 출력하지 않는다. trust-init: 빈 입력·텍스트·개인키·CA 아님·만료·PEM 괄호 불균형을 거부하고 실패 시 `cacerts`를 남기지 않는다. 주입 테스트는 ECS가 넣는 형태(원본 SecretString 한 줄)와 env-file에서 PEM이 바이트 동일하게 유지됨을 확인한다. | 아래 결과 |

### 10.2 재현 명령 (Windows Git Bash 기준, 저장소 루트에서)
```
export AWS_PROFILE=ranikun-admin MSYS_NO_PATHCONV=1
RUN_AWS_SIM=1 TERRAFORM=<terraform 경로> sh candidates/carelog-tls/tests/run-all.sh
```
- 필요한 것: Docker, 로컬에 있는 Core 이미지 digest(라이브 `sha256:ad9f84…`, 없으면 ECR 로그인 후 pull), 읽기 전용 AWS 프로필(IAM 시뮬레이션 단계). 생성 키·인증서는 임시 디렉터리에서 만들고 끝나면 지운다.
- `RUN_AWS_SIM`을 빼면 IAM 시뮬레이션을 건너뛴다. `TERRAFORM`을 빼면 platform Terraform 단계를 건너뛴다. `SKIP_LINT=1`로 lint를 건너뛸 수 있다.
- 프록시 테스트 단독: `sh candidates/carelog-tls/test-proxy.sh <이미지 태그>` 또는 컨테이너 안에서 인자 없이 실행(Git Bash에서는 `MSYS_NO_PATHCONV=1` 필요). 그 앞에서 `docker build -t <태그> candidates/carelog-tls`.
- Terraform 단독: 각 `environments/dev/{carelog,platform,finance,shared}`에서 `terraform init -backend=false`, `fmt -check -recursive`, `validate`, `test`.

### 10.3 결과 (이 문서 작성 시점의 작업 트리, 리드가 직접 실행)
| 항목 | 결과 |
|---|---|
| `run-all.sh` (RUN_AWS_SIM=1, TERRAFORM 지정) | OVERALL PASS rc 0, 하위 검사 77 PASS / 0 FAIL |
| 포함된 단계 | 프록시 빌드, Core 이미지 확인(라이브·이전), trust-init 빌드(라이브·이전), 기반 digest 검사, 프록시 엔트리포인트 16건, 주입 6건, trust-init 12건, JDK 신뢰, Core digest 5건, IAM 시뮬레이션 27건, Carelog `test-proxy.sh`, hadolint, shellcheck, actionlint, platform Terraform fmt/init/validate/test |
| Terraform test | carelog 10, platform 7, finance 1, shared 2 건 모두 통과, `fmt -check` 네 루트 통과, `validate` 통과 |
| `test-proxy.sh` (호스트 방식·컨테이너 방식) | 둘 다 PASS (80건) |

### 10.4 한계와 열린 항목
- 라이브 DEV state에 대한 `terraform plan`은 이번에 실행하지 않았다(실제 이미지·Secret 참조가 없고, Core 환경 변수 비교는 mock 기준이다).
- 이전 준비 문서의 수치(117개)는 기반 이미지 `8353cec4…` 기준이었다. 라이브 Core `:3`의 이미지는 `ad9f84…`이고 `cacerts`가 118개다. trust-init은 반드시 라이브 digest를 기반으로 빌드한다.
- 실제 ECS Secret 주입, Fargate 메타데이터 IP, 실제 CA 체인, Spring Boot 앱 테스트는 검증하지 못했다. 헬스 체크의 서버 인증서 비교는 오래된 리스너는 잡지만 잘못된 번들로 다시 로드된 경우는 못 잡는다.
- IAM 시뮬레이션은 문서를 따로 평가한다. 실제 권한은 인라인 정책과 boundary의 교집합이다. 모듈이 Secret ARN에 `ssm:GetParameters`도 부여하는 기존 동작은 필요 이상으로 넓다.
- 저장소 변수 `DEV_CORE_TASK_IMAGE`(Core Task의 digest)를 설정해야 초안 워크플로가 동작한다. 공개 CA 번들 파일 `candidates/carelog-tls/ca/carelog-dev-ca-bundle.pem`은 소유자가 커밋해야 한다. 복구 담당 정책과 Deny 연결 승인(`prep-aws-changes.md` 11행)이 필요하다.

## 11. 외부 재검토 MAJOR 2건 반영 (기준 b4cd59d)

AWS 쓰기, ECS 적용, 새 plan은 없다. 단일 Secret 설계를 유지했다.

### 11.1 MAJOR 1: 가입 활성 시에만 Spring 프로필 `dev` 추가
- 규칙(`environments/dev/platform/core_env.tf`): 가입 비활성이면 Core 환경이 라이브와 정확히 같다. 가입 활성이면 기존 프로필 목록 뒤에 `dev`를 한 번만 덧붙인다(공백 제거, 대소문자 무시, 중복 없음; 라이브가 비어 있으면 `dev`, `a, b`는 `a,b,dev`). 기존 또는 후보 목록에 `prod`·`production`(대소문자 무관)이 있으면 plan이 실패한다(키 이름만 출력).
- 암묵적 `default` 프로필: platform-core(소스 `dc63569`)에는 프로필별 설정 파일과 `@Profile("default")`가 없어 `dev`만 활성이 되어도 잃는 설정이 없다. `dev` 프로필을 읽는 곳은 가입 등록 경로(`CarelogRegistrationCompositionConfiguration.java:47`, `requireDevComposition`: dev, prod 아님, 가입 활성)이고, 가입 클라이언트 자체(`CarelogEnrollmentClientConfiguration.java:15`)는 프로필 조건이 없다. 요청대로 가입 활성에 `dev`를 붙이되, 가입만으로 `dev`가 필요한 것은 아니라는 점을 기록한다.
- JVM 옵션: 기존 `JAVA_TOOL_OPTIONS`를 순서대로 보존하고 없는 truststore 옵션만 덧붙인다. 같은 옵션이 중복되면 마지막 값이 이긴다(Core 이미지 JDK 21에서 실험). 따라서 기존에 다른 `trustStore`·비밀번호·형식이 있으면 조용히 덮어쓰지 않고 plan을 실패시킨다. 저장소 형식은 기본값 pkcs12와 같다.

### 11.2 MAJOR 2: 가입 지원 Core 이미지 고정과 대조
- 후보 Core 이미지를 `sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf`로 고정했다(코드 상수, 예시 입력, 테스트, 워크플로 초안). 라이브 `ad9f84…`는 "기존 CA 유지"와 음성 테스트의 기준으로만 쓴다.
- 직접 대조: 입력 `enrollment_core_candidate`의 Core 이미지와 `trust_init_core_base`가 digest 형식이며 같지 않으면 Terraform 검증이 실패한다. `tests/check-core-digest.sh --tfvars`가 등록할 Core 입력과 trust-init의 라벨(`ranikun.carelog.core-base`)·레이어를 대조한다. 워크플로는 빌드 전후에 같은 검사를 한다. 저장소 변수 `DEV_CORE_TASK_IMAGE`는 이제 후보 digest를 뜻한다(설정하면 반드시 같아야 한다).
- CA: 개수를 고정하지 않는다. 기반 이미지의 별칭 목록을 계산해 모두 남는지 확인하고, 가져온 CA 수만큼만 늘어나는지(1개→+1, 2개→+2) 확인한다.
- 이미지 근거(`evidence-core-image.md`): 발행 run `44921734845` success, 태그 SHA·run head·소스 커밋 `dc635694…` 일치, digest 일치. 배포 승인은 없다(deploy skipped, 배포 기록 없음, PR #71 리뷰 0건). 후보에는 가입 클라이언트, 등록 컨트롤러, Core 마이그레이션 V3가 있고 라이브 `ad9f84…`에는 없다.

### 11.3 항목 3: SAN 비교와 롤백 문구
- `grep -Fqx` 비교를 제거했다. 기대 이름은 일반 DNS 이름(영문·숫자·점·하이픈, 와일드카드·공백·줄바꿈·정규식 문자 거부)만 허용하고 소문자와 후행 점을 정규화한다. 검사는 인증서의 DNS SAN 전체 값과의 정확한 일치(awk 한 번)이며 IP SAN은 일치하지 않는다. 접두·접미·부분 문자열·와일드카드 인증서·IP만 있는 인증서·줄바꿈 삽입·정규식 문자는 모두 거부하고, 대소문자·후행 점·목록 안의 이름은 통과한다.
- 구버전 인증서 롤백 문구: 단일 번들의 이전 Secret 버전 복원(`AWSCURRENT` 이동) → 새 배포 → 서빙 인증서 지문 확인 → 계속 실패하면 Task revision `:6`으로 롤백. 인증서·키를 따로 두는 서술은 3-Secret 대안 절에만 남겼다. 가입용 Bearer Secret은 어떤 롤백 단계에서도 건드리지 않는다.

### 11.4 Core V3·Carelog V9 적용 여부 (조회 가능한 경로만, 상세: `evidence-flyway-v9.md`)
| 마이그레이션 | 결과 | 근거 |
|---|---|---|
| Core V3 (`identity` 스키마) | 마지막으로 기록된 시작 기준 **미적용** | Core 로그 2026-11-21 03:02~03:11Z에 V1·V2까지만 적용, 이후 Flyway 줄 없음. 수동 SQL 기록은 없으나 있었는지는 알 수 없다 |
| Carelog V9 (`public` 스키마) | **알 수 없음** | 로그에 Flyway 줄 0건, 어떤 revision도 Flyway를 켜지 않음 |

**중요**: 후보 Core 이미지는 시작할 때 Flyway가 자동으로 V3를 적용한다(`IdentityPersistenceConfiguration.java:110-112` → `IdentityLegacySchemaGuard.java:31`, 끄는 스위치 없음, 영속성은 기본 활성). 즉 후보 Core Task를 DEV에서 처음 시작하는 것이 곧 DEV DB 스키마 변경이며 승인 게이트가 없다. 별도 승인된 변경 절차 전에는 후보 Core를 시작하지 않는다. Carelog는 시작 시 마이그레이션을 하지 않으며 V9가 없으면 스키마 검증에서 시작이 실패한다(DDL은 실행되지 않음). 둘은 같은 `dev-shared` 클러스터의 `app` 데이터베이스를 쓴다. 확정하려면 DEV VPC 안에서 읽기 전용 계정으로 `evidence-flyway-v9.md`의 조회 쿼리를 실행해야 한다.

### 11.5 재현 명령과 결과 (리드가 직접 실행)
```
export AWS_PROFILE=ranikun-admin MSYS_NO_PATHCONV=1
RUN_AWS_SIM=1 TERRAFORM=<terraform 경로> sh candidates/carelog-tls/tests/run-all.sh
# 각 루트: terraform init -backend=false; fmt -check -recursive; validate; test
```
| 항목 | 결과 |
|---|---|
| `run-all.sh` | OVERALL PASS rc 0. 단계 27개 통과, 하위 검사 104 PASS / 0 FAIL |
| 하위 구성 | 프록시 엔트리포인트 28, 주입 6, trust-init 12+12(후보·라이브), JDK 신뢰 11, Core digest 8, IAM 시뮬레이션 27, Carelog `test-proxy.sh`, lint 전부 통과 |
| Terraform test | carelog 10, platform 23, finance 1, shared 2 통과. 네 루트 `fmt`·`validate` 통과 |

### 11.6 한계와 열린 항목
- 라이브 DEV state에 대한 plan은 실행하지 않았다(mock 기준). 실제 ECS 주입, Fargate, 실제 CA 체인, 앱 테스트, 역할 생성 후의 `simulate-principal-policy`는 하지 않았다.
- 판단은 소스 `dc63569`와 이미지 태그 접두어에서 추정한 것이다(Dockerfile 출처 라벨 아님).
- 정해야 할 것: 후보 Core의 V3 자동 적용 승인, DEV DB 읽기 전용 조회 담당과 경로, 공개 CA 번들 파일 커밋 담당, `DEV_CORE_TASK_IMAGE` 설정, 복구 담당 정책과 Deny 연결 승인(`prep-aws-changes.md` 11행), 가입에 `dev`가 정말 필요한지, 새 Carelog 이미지의 DEV 배포 승인자. Gateway 후보 `1b00276e…`는 발행·배포 상태만 확인했다.

## 12. 3차 외부 리뷰 반영 (기준 17cf19e)

AWS 쓰기, DEV DB 변경, Terraform apply, 새 Core 기동은 하지 않았다. 격리 테스트는 로컬 Docker에서만 했다.

### 12.1 A · 가입 설정과 배포 절차
- **가입 ON은 전부 갖춰야 plan이 통과한다** (`environments/dev/platform/core_env.tf`): Core 이미지 `8353cec4…`, digest 고정 trust-init(같은 digest 기반), `carelog-trust` 볼륨과 읽기 전용 마운트, `dependsOn` SUCCESS, trustStore 옵션, `dev` 프로필, 가입용 Secret 참조가 모두 있어야 한다. Core에 TLS 서버 번들 Secret이 들어가면 거부한다. 빠진 항목마다 이름만 보여 주며 실패하고 항목별 음성 테스트가 있다. 가입 OFF면 환경·Secret 이름과 개수가 라이브와 같다.
- **가입 OFF여도 V3 관문**: Core 이미지가 라이브와 다르면 `core_v3_db_change_approval`(승인 근거와 V3 상태 확인 시각)이 필요하다. 비어 있거나 `REPLACE`로 시작하거나 시각 형식이 틀리면 plan이 실패한다. 이는 문서상의 관문이며 실제 승인의 증명이 아니다. 롤아웃 문서(`carelog-tls-ecs-rollout-rollback.md`)에 8.1절 "Core V3 pre-start gate"를 넣었다: 읽기 전용 V3 조회, 승인 기록, desired 0 유지, 롤백 영향, 중단 조건.
- **후보 trustStore 충돌 거부**: 우리 옵션이 아닌 `trustStore`·비밀번호·형식, 같은 키의 서로 다른 값, `trustAll` 계열 패턴, `trustStore=NONE`은 plan 실패(키 이름만 출력). 인증서 폐기 확인 토글은 허용한다.
- **구·신 Core CA 차이** (`prep-cert-secrets.md` 14·15절, `tests/ca-store-diff.sh`): 라이브 `ad9f84…` 118개, 후보 `8353cec4…` 117개. 차이는 라이브에만 있는 Izenpe 루트(CN Izenpe.com, 2037-12-13 만료) 하나이고 후보에만 있는 것은 없다. 원인은 JDK 21.0.13과 21.0.13.1로 추정(JDK 변경 이력은 확인하지 않음). ISRG X1·X2, Amazon Root CA 1~4, Starfield G2는 양쪽에 지문이 같다. 연결별 영향: Redis TLS(ISRG 체인)·RDS(`sslmode=require`, pgjdbc 문서 근거)·Carelog(HTTP/사설 CA)는 영향 없음, 나머지 연동은 현재 설정에 없다. 모든 외부 호스트를 조사하거나 라이브 로그를 읽지는 않았다. 테스트는 차이 목록이 `ca-expected-differences.txt`와 정확히 같을 때만 통과한다.

### 12.2 B · 격리 PostgreSQL 롤백 실증 (`evidence-core-rollback-test.md`, `candidates/core-rollback-test/run.sh`)
환경: PostgreSQL 16.15, 이전 Core `ad9f84…`(V1·V2), 새 Core `8353cec4…`(V3), 일회용 값. DEV DB에는 연결하지 않았다.

| 단계 | 결과 |
|---|---|
| 1 이전 Core로 V1·V2 DB 준비 | PASS |
| 2a 런타임 역할만으로 새 Core, V3 적용 전 | 기동 실패(예상), V3 적용 안 됨 |
| 2a2 이력 조회 권한을 줘도 V3 보류 상태 | DDL 권한 부족으로 실패(예상) |
| 2b 마이그레이션 역할로 새 Core | V3 적용(성공, 이력 1행) |
| 2c·2c2 V3 후 런타임 역할 | 이력 조회 권한이 없으면 실패, 있으면 기동 |
| 4a 새 Core 로그인·토큰 갱신·비밀번호 변경 | 200 / 200 / 정상 |
| 3 V3가 있는 DB에 이전 Core, 기본 Flyway 설정 | **기동 성공** (차단되지 않음) |
| 4b 이전 Core 로그인·토큰 갱신·비밀번호 변경 | 200 / 200 / 정상 |
| 3 `ignore-migration-patterns=*:future` | 기동 성공 |
| 3 `*:missing`만 지정해 기본값을 덮어쓰면 | 차단("Detected applied migration not resolved locally: 3") |
| 5 새 Core 재전환 | V3 재실행 없음(같은 순번·체크섬), 데이터 건수 동일, 로그인 200 |
| 5 가입 재시도 | **건너뜀** (가입 클라이언트는 https 또는 루프백만 허용, 격리 환경에 Carelog 가입 엔드포인트가 없음) |

- **롤백 판정**: 이전 Core `ad9f84…`는 V3가 남은 DB에서 롤백 대상으로 쓸 수 있다(설정 변경 없이). 조건: (C1) 마이그레이션 데이터소스와 Flyway 기본 `*:future` 허용을 유지하고 `*:missing`만으로 덮어쓰지 않는다. (C2) Flyway가 런타임 역할로 돌면 그 역할에 `flyway_schema_history` SELECT가 필요하다(없으면 두 이미지 모두 실패). (C3) 롤백과 재전환에서 V3는 재실행되지 않는다. 이미지를 롤백해도 V3 스키마는 DB에 남는다.
- **역할 구분 주의**: 격리 테스트는 마이그레이션 역할(스키마 소유자)과 런타임 역할(DML만)을 나눠 시험했다. 그러나 라이브 Core Task 정의는 런타임과 Flyway 자격 증명이 모두 `shared-db-admin`을 가리킨다(Task 정의 이름 기준). 따라서 라이브에서는 C1·C2가 관리자 자격 증명으로 충족되는 대신 런타임이 사실상 DB 소유자다. 역할 분리를 증명한 것이 아니며, 앱에는 Flyway를 앱 밖에서 실행하는 스위치가 없어 분리하려면 platform-core 변경이 필요하다. DEV의 실제 스키마 소유자·권한·`search_path`는 확인하지 못했다.
- 코드 읽기만으로 확인한 것: 마이그레이션 때마다 런타임 역할의 `flyway_schema_history` 권한을 회수하는 코드(`IdentityRuntimeSchemaPrivileges.reconcile`)가 있다. 이번 실행에서 재확인하지는 않았다.

### 12.3 재현 명령과 결과 (리드가 직접 실행)
```
export AWS_PROFILE=ranikun-admin MSYS_NO_PATHCONV=1
bash candidates/core-rollback-test/run.sh          # 약 6분, Docker 필요, 이미지는 로컬에 있거나 ECR 읽기 전용 pull
RUN_AWS_SIM=1 TERRAFORM=<terraform 경로> sh candidates/carelog-tls/tests/run-all.sh
# 각 루트: terraform init -backend=false; fmt -check -recursive; validate; test
```
| 항목 | 결과 |
|---|---|
| `core-rollback-test/run.sh` | rc 0, 실패 0 (통과 19, 건너뜀 1, 테스트 컨테이너 잔여 없음) |
| `run-all.sh` | OVERALL PASS rc 0, 단계 28 통과, 하위 검사 107 PASS / 0 FAIL (CA 차이 3건, IAM 시뮬레이션 27건 포함) |
| Terraform test | carelog 10, platform 44, finance 1, shared 2 통과. 네 루트 `fmt`·`validate` 통과 |

### 12.4 DEV에서 아직 확인할 항목
- DEV DB의 Core V3·Carelog V9 적용 여부(현재 근거: V3 미적용은 2026-11-21 03:11Z 기준, V9 알 수 없음). 읽기 전용 계정과 접속 경로 필요, 조회 쿼리는 `evidence-flyway-v9.md`.
- DEV 스키마 소유자, 런타임 역할의 권한, `search_path`, Flyway가 어떤 데이터소스로 도는지(라이브 Task 정의는 둘 다 `shared-db-admin`).
- 실제 Aurora(TLS), 데이터 양에 따른 `ALTER TABLE` 잠금 시간, 가입 재시도(Carelog 가입 엔드포인트가 있는 환경), ALB·ECS 헬스·Secret 주입.
- 결정: V3를 공유 관리자 자격 증명으로 실행해도 되는지, 승인 기록자와 위치(`core_v3_db_change_approval`), Izenpe 루트가 필요한 엔드포인트가 있는지.
