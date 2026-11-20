# Carelog · Finance DEV 릴리스 시작 순서

이 저장소의 Terraform은 공용 인프라와 기존 이미지 digest를 소비한다. 추가 release 루트가 ECR과 권한을 먼저 만든 뒤 소스 저장소의 workflow에서 첫 이미지를 발행할 수 있다. 구성은 DEV 전용이다.

| 실행 순서 | 실제 입력과 검증 |
| --- | --- |
| 1. AWS 읽기 전용 실사 | DEV 계정·리전, S3 백엔드·잠금, GitHub OIDC provider와 기존 ECR 소유권 확인. 이미 관리 중인 리소스는 상태와 비교 후 import 또는 재사용 절차 선택 |
| 2. Release 루트별 계획 | `environments/dev/release/{platform,carelog,finance}`의 역할과 ECR을 각 상태로 관리. 기존 OIDC provider ARN을 명시. 신규 리소스 및 비용 권한 확인 후 루트별 plan/apply |
| 3. GitHub 환경 | 각 앱 저장소에서 `dev-<service>-publish`, `dev-<service>-deploy` 생성. Platform/Finance는 main, Carelog는 dev 경로로 환경 보호. 설정은 아래 표를 참조. 공개된 고정 workflow 커밋을 각 호출자가 사용해야 함 |
| 4. 첫 이미지 | 테스트를 통과한 dispatch SHA에서 배포 선택을 꺼 두고 ECR에 발행. 산출된 digest를 해당 ECS 루트의 최초 이미지로 사용 |
| 5. ECS 부팅 | 기존 DEV 실행 안내대로 0 Task에서 설정과 SG·DB 권한을 준비하고 승인된 범위에서 1 Task 기준선 시작 |
| 6. 후속 릴리스 | 해당 서비스에서 deploy 옵션 선택. 현재 완료된 revision을 읽어 이미지 필드만 바꾸고, 새 revision이 완료되는지 확인. 실패 시 해당 릴리스가 여전히 소유하는 배포에서 직전 revision 복구를 시도 |
| 7. 사용자 인수 | 두 제품의 Cloudflare URL과 실제 API/인증을 확인하고 브라우저에서 로그인과 저장·재조회, 실패한 릴리스의 실제 복귀를 검증 |

## GitHub 환경 변수

| 변수 | publish | deploy |
| --- | --- | --- |
| `DEV_AWS_ACCOUNT_ID`, `AWS_REGION`, `DEV_ECR_REPOSITORY` | 필요 | 필요 |
| `DEV_PUBLISHER_ROLE_ARN` | 필요 | |
| `DEV_DEPLOYER_ROLE_ARN`, `DEV_ECS_CLUSTER`, `DEV_ECS_SERVICE`, `DEV_ECS_CONTAINER`, `DEV_ECS_TASK_FAMILY` | | 필요 |

ECR 리포지토리 이름, 역할 ARN, ECS 이름·family·container는 release 루트와 기존 ECS 루트의 실제 출력에서 대조해 입력한다. Role trust는 호출 저장소의 지정 DEV 환경에만 열려 있다. GitHub 환경의 배포 브랜치 및 승인 설정은 저장소에서 실제로 검증한다. AWS 실행 역할과 Terraform 상태 접근 권한은 별개다.

이미지는 불변 태그로 발행하고 digest를 추적한다. ECR 스캔은 비동기로 진행되며 워크플로가 조회한 시점의 상태를 표시한다. 정식 스캔 결과를 배포 검수에서 확인한다. 앱 설정과 이미지 revision을 복제할 때 기존 task-definition 태그는 입력에 포함하지 않으므로 태그 전파·비용 분류를 사용할 운영은 별도 검증한다. workflow의 리포지토리 내 서비스별 동시 실행 제한과 운영자의 단일 변경 주체 원칙을 함께 적용한다. ECS에는 조건부 update-service가 없으므로 자동화, 수동 작업, 다른 리포지토리의 배포가 동일 서비스에 동시에 쓰지 않게 한다. 러너 취소나 AWS 응답이 모호하면 실제 ECS 서비스의 primary revision, task count, 이벤트를 확인한 뒤 재시도하거나 복구한다.

Core, Carelog, Finance는 실행 중인 컨테이너 설정에 `SPRING_FLYWAY_ENABLED=false`가 명시되어 있어야 이미지 배포가 진행된다. 기본 시작 시 마이그레이션을 쓸 수 있는 앱이므로 첫 ECS revision에도 같은 설정을 넣는다. 사전에 별도 역할로 정확한 DB 대상, 이력과 체크섬을 확인하고, 필요한 schema 변경을 단일 마이그레이션 경로로 적용한다. 새·이전 버전이 해당 schema와 모두 동작한다는 증거를 보관한다. 자동 앱 롤백은 DB를 복원하지 않는다. 사용자 검증과 DB 마이그레이션은 별도 절차에서 진행한다.

## 서비스별 실행 설정

| 서비스 | 빌드 기준 | 앱 / 운영 포트 | 현재 확인 사항 |
| --- | --- | --- | --- |
| Gateway | Java 17, gateway-app 컨텍스트 | 8080 / 9091 | ALB의 readiness는 9091. 관리 포트는 ALB 검사 경로에만 열고 실제 SCG 라우팅과 Redis TLS 검증 |
| Platform Core | Java 21, platform-core 컨텍스트 | 8081 / 9092 | Aurora 및 Identity Redis 필요. 옵션 TLS는 정확한 릴리스와 실제 AWS endpoint로 확인 |
| Carelog BE | Java 17, repo root 컨텍스트 | 코드 기본 8080 / prod-profile 관리 8081 | 실제 AWS DEV profile, 제품 DB/Secret, SCG auth와 고객·일정 저장 검증 |
| Finance BE | Java 21, repo root 컨텍스트 | 앱 포트는 실제 runtime 설정 확인 / 기본 관리 8081 localhost | 보통의 Shared Identity 로그인과 제품 라우팅 기준 확인. Synthetic reference auth를 공개 DEV에 사용하지 않음 |

CPU/RAM, 이미지 아키텍처, Hikari 상한, 롤링 중 최대 task 수, 드레이닝·기동 지연, 로그 보존과 quota는 실제 승인 입력에서 결정한다. JVM 메모리와 DB 연결 수는 첫 기동·롤링에서 계측하며, 보안 그룹·OAuth·DB 및 Secret 구성은 기존 실행 안내에 따른다. SQS 실소비·Outbox, 활성 알림과 복원, 절전은 제품 기준선 검증 이후 단계에서 증거를 남긴다.

[DEV ECS 실행 안내](dev-ecs-runbook.md) · [ECR·OIDC Terraform 입력](../environments/dev/release/README.md)
