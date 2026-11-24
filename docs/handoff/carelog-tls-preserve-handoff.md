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
