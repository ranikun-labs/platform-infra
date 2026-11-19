# Carelog·Finance DEV Terraform 실행 안내

대상은 AWS DEV의 기존 SCG, Platform Core, Carelog BE, Finance BE이다. 현재 소스는 실행 검토용 후보이며, 대상 계정의 AWS 인벤토리·비용·변경 승인을 확인한 뒤 기존 자원과 대조해야 한다.

## 루트와 입력

| 루트 | 소유 대상 | 넘길 값 |
| --- | --- | --- |
| `shared` | VPC, 두 AZ의 public/private 서브넷, 선택형 NAT, Aurora, private Valkey 후보, ECS 클러스터, Cloud Map, DB/Valkey 유입 규칙 | VPC·서브넷 ID, 클러스터 ARN, Cloud Map ID와 이름, DB·Valkey 주소 |
| `platform` | 공개 HTTPS ALB, SCG IP 대상 그룹, Gateway와 Core의 사설 태스크, 계약 기반 Audit Queue/DLQ | SCG SG ID, Core SG ID, ALB DNS·Hosted Zone, 서비스 이름·태스크 revision |
| `carelog`, `finance` | 제품별 서비스, 로그, IAM, Cloud Map, SCG에서 제품으로 들어오는 유입 규칙 | 제품 SG ID, 서비스 이름·태스크 revision |

DEV state는 `dev/{shared,platform,carelog,finance}/terraform.tfstate` 키와 각각의 S3 lockfile을 사용한다. 승인된 S3 버킷·리전·암호화·키별 IAM은 초기화 전에 외부에서 준비한다. 같은 버킷의 state를 다른 루트 역할로 읽거나 쓸 수 없는지 확인한다. 제품 역할에는 공용 DB 또는 Valkey SG 수정 권한을 부여하지 않는다. 루트 사이에는 위 식별자만 전달하고 DB 관리자 암호나 런타임 Secret 값을 입력 파일과 plan 로그에 담지 않는다. 앱에서 사용할 역할별 DB 계정과 Secret 참조는 별도 준비한다.

## DEV 최초 기동 순서

1. DEV 계정과 리전, 기존 리소스, S3 state, DNS/ACM, ECR digest, 외부 OAuth 및 HTTPS egress, Aurora 호환 버전, DB schema/role, 승인된 앱 시크릿과 비용 한도를 먼저 확인한다. 이미 관리 중인 자원은 소유 상태를 확인하고 필요하면 별도 import plan을 준비한다.
2. `shared`를 빈 데이터 유입 규칙으로 적용한다. 공개 웹 흐름을 열기 전 PostgreSQL 호환 및 DB 백업·복구를 검증한다. Valkey 후보는 기본 비활성이고 기존 인증에 맞는 TLS 연결·상태 보존 방식을 확인해야 한다. NAT 후보는 단일 AZ DEV 구성이다.
3. `platform`과 제품 두 루트는 처음에 0 Task로 초기화한다. Platform과 제품 간 SG ID를 먼저 맞추고 Carelog/Finance를 병렬로 준비한다. Cloud Map 이름과 앱 URI·포트를 동일한 계약으로 설정한다.
4. `shared`에서 승인된 워크로드 SG만 DB/Valkey에 허용한다. 제품 마이그레이션 담당자가 승인된 단일 실행 경로를 사용해 DB 역할·스키마를 검증한다. DB 관리자 Secret ARN은 관리 경로 전용이다.
5. 지정된 DEV 서비스에서 한 태스크씩 시작하고 Cloud Map·ALB readiness 뒤 실제 OAuth·제품 API를 확인한다. Carelog 고객/후속 일정과 Finance 저널의 저장·목록·상세·재조회까지 각각 검증한다. Finance의 실계정 경로에는 승인된 SCG 전용 라우팅·Identity 계약이 필요하다. 로컬 synthetic reference auth를 공개 DEV 인증에 사용하지 않는다.

GitHub의 기본 검사 workflow는 backend 없이 검사한다. 실제 plan/apply는 계정과 루트가 확인된 별도 환경에서 단일 루트의 검토 대상 커밋과 실행 역할로 진행한다. 저장한 plan을 비공개로 취급하고, 승인받은 동일 plan만 적용한다. Merge는 apply를 시작하지 않는다. IaC는 설정 변경으로 생긴 baseline task definition을 등록한다. 실행 중인 revision과 desired count의 변경은 해당 서비스의 릴리스·스케일 제어 절차가 맡는다. 구성 변경으로 baseline revision이 바뀌면 릴리스 절차에서 그 revision을 검토 후 활성화한다.

## SQS와 절전 검증

- Shared Audit Queue/DLQ는 승인된 AU-G3 계약과 역할을 지정했을 때만 생성하는 후보 구성이다. 실제 Consumer, Ledger, 생산자 Outbox와 AWS Dev 통합 검증이 있어야 작업 처리·복구가 확인된다. 제품별 Queue·Worker는 실제 업무를 정한 뒤 각 루트에서 관리한다.
- 최소 1 Task에서 먼저 제품 흐름을 검증하고, 지원되는 Aurora 엔진에서만 0 ACU 후보를 시험한다. 긴 유휴 뒤 첫 요청, DB 연결 반환, Pool/Health/Poll이 자동 pause에 미치는 영향과 복구 비용을 측정한다.
- V1 기동은 승인된 단일 서비스 수동 제어로 검증한다. 예약/자동 기동에는 별도의 제어 경로와 중복 방지·활성 작업 보호가 필요하다. HTTP 0→1, SQS 소비 0→1, DB 커밋 후 미발행 Outbox 복구를 각각 검증한 뒤 통합한다.
- 초기 AWS plan/apply, 실행 시뮬레이션 밖의 격리 테스트, 실제 OAuth/API, SQS 처리, 절전 복구와 비용 실측은 DEV 실행 승인과 인벤토리 확인 이후 증거를 남긴다.

[플랫폼 소유권 계약](ownership-and-isolation.md) · [Confluence AWS 실험 허브](https://ranikunlabs.atlassian.net/wiki/spaces/RLAB/pages/26935297) · [ADR-0023 SQS](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0023-sqs-messaging-and-environment-isolation.md)
