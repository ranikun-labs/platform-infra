# 인프라 소유권·독립 운영 계약 v0.1

**대상:** Ranikun Labs의 Shared Platform · Carelog · Finance · oh-my-ai  
**상태:** C0 설계 문서 / 검토 요청 단계. **인프라가 실제 구현되었다는 증거는 아닙니다.**  
**추적:** [Infra Issue #1](https://github.com/ranikun-labs/platform-infra/issues/1)

## 1. 결론 — 어떤 운영 구조를 만들려는가?

**하나의 `platform-infra` 저장소에서 인프라를 정의하되, 각 제품은 독립적으로 개발·배포·복구합니다.**

예를 들어 Carelog CRM 기능을 배포했는데 Finance Backend가 재빌드되거나 재시작된다면 설계 위반입니다. Finance의 인프라 변경이 Carelog의 인프라 상태나 데이터베이스 마이그레이션을 실행해도 설계 위반입니다.

공통 Gateway·Identity 변경은 두 제품과의 API 호환성을 검토할 수 있지만, **모든 제품을 동시에 배포하도록 강제하지 않습니다.**

## 2. 현재 상태와 목표를 구분

| 항목 | 현재 확인된 상태 | 목표 |
| --- | --- | --- |
| 인프라 저장소 | Private 저장소의 C0 설계 문서 존재 | 공유/서비스별 IaC 정의 |
| CI/CD 독립성 | 실제 Pipeline·IAM 격리 검증 전 | 제품별 독립 실행과 배포 |
| AWS EC2 / RDS | 이 문서로 구축한 자원 없음. 실제 인프라 존재 여부는 별도 점검 필요 | AWS 서울 리전의 서비스별 EC2 + 공통 RDS |
| DB 소유권 | ADR-0020의 정책 승인. 제품별 운영 이전은 별도 작업 | 서비스별 Schema·Role·Migration 분리 |
| oh-my-ai | 로컬 CLI·Skill 중심 | 클라우드 없이 로컬 V1 동작 |
| Production 배포 | 이 계약에 포함하지 않음 | 별도 Owner 승인과 운영 검증 |

**기존 ADR의 목표 설계와 실제 실행·배포 상태를 동일하게 취급하지 않습니다.**

## 3. 책임을 어떻게 나누나?

| 관리 대상 | 최종 소유자 | 변경·배포 영향 |
| --- | --- | --- |
| 네트워크(VPC), 물리 RDS 등 공통 기반 | `platform-infra/shared` (예정) | 여러 제품에 영향 가능 → 별도 승인 |
| Gateway·Platform Core 실행 환경 | `platform-infra/platform` (예정) | Shared Platform 단독 |
| Carelog 전용 서버·권한·배포 구성 | `platform-infra/carelog` (예정) | **Carelog만** |
| Finance 전용 서버·권한·배포 구성 | `platform-infra/finance` (예정) | **Finance만** |
| 각 제품의 애플리케이션 코드·Dockerfile·로컬 Compose·테스트 | 해당 제품 소스 저장소 | 해당 제품의 개발·검증 |
| DB 테이블/마이그레이션 정의 | 해당 도메인 소유 저장소 | 해당 Schema에만 적용 |
| 로컬 Skill·CLI·Hook | `oh-my-ai` | 독립 로컬 릴리스 |
| 공식 정책·배포 목표 | `harness-foundation-docs`의 발효된 ADR | 새로운 결정은 별도 검토 |

**소유권과 운영 책임은 별개입니다.** Infra 저장소가 서버를 관리한다고 해서 Finance 데이터 테이블이나 Carelog Flyway 마이그레이션을 직접 소유하지는 않습니다.

## 4. 절대 위반하면 안 되는 독립성 규칙

### 4.1 Carelog ↔ Finance

- Carelog 변경·PR·배포·재시작·복구는 Finance의 Build/Test/Deploy/Restart/Rollback/DB Migration/Infra Apply를 **자동 실행하지 않습니다.**
- Finance에서도 반대 방향으로 동일한 규칙을 적용합니다.
- 한 제품을 위한 Terraform 실행이 다른 제품 자원을 수정하거나 삭제할 수 없어야 합니다.
- 공통 자원 변경 시 **두 제품의 영향은 분석하되, 두 제품을 함께 배포하지는 않습니다.**

### 4.2 Shared Platform

- Gateway와 Platform Core는 별도 실행·배포 경계이며, 제품들의 인증·라우팅 계약을 제공합니다.
- Platform Identity 변경 때문에 Carelog와 Finance가 같은 시점에 새 버전을 배포하도록 강제해서는 안 됩니다.
- 양쪽 버전이 공존할 수 있는 호환 기간, 전환 순서, Rollback 조건을 별도로 입증합니다.

### 4.3 oh-my-ai

- 현재의 `oh-my-ai` V1은 로컬에서 설치·실행·사용할 수 있어야 합니다.
- Carelog·Finance 서버나 AWS 공통 플랫폼 장애가 있어도 핵심 로컬 작업 흐름은 완료할 수 있어야 합니다.
- 향후 별도 Cloud Control Plane이 승인되기 전까지 AWS 배포 대상으로 강제로 편입하지 않습니다.

## 5. 초기 AWS 목표와 공통 장애 위험

[ADR-0022](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0022-aws-v1-mvp-primary-runtime.md)는 다음 **목표 배치**를 정합니다.

| 실행 단위 | 목표 배치 | 운영 의미 |
| --- | --- | --- |
| Gateway | EC2 #1 | 인터넷 요청의 공통 진입 |
| Platform Core | EC2 #2 | Identity·Shared AI·Shared Audit 논리 모듈 |
| Finance Backend | EC2 #3 | Finance 독립 배포·복구 |
| Carelog Backend | EC2 #4 | Carelog 독립 배포·복구 |
| PostgreSQL | Private RDS 1개 / Application DB 1개 | 서비스별 스키마·역할로 데이터 소유권 분리 |
| Valkey | Core 동거 후보 | 실제 위치·Private Network·복구 검증은 별도 Gate |

이는 실제 AWS 리소스 생성 승인이 아닙니다.

**공통 RDS가 장애 나면 Carelog·Finance·Platform이 함께 영향을 받을 수 있습니다.** 서비스별 스키마는 접근 권한·데이터 소유권을 분리하지만, 물리적인 가용성까지 분리하지는 못합니다. 초기에는 비용상 공유할 수 있으나 RDS 복구·백업·용량·장애 대응을 공통 기반의 별도 작업으로 관리해야 합니다.

## 6. DB·인프라 상태·IAM·Secrets 경계

### 데이터베이스

하나의 PostgreSQL Application Database 안에서 `identity`, `carelog`, `finance` 및 추후 `audit` 스키마를 구분합니다.

- 각 스키마의 테이블 및 Flyway 마이그레이션은 소유 서비스만 변경합니다.
- 서비스마다 실행 계정과 마이그레이션 권한을 독립적으로 제한합니다.
- 제품이 Identity 데이터를 읽어야 하면 **Identity API/서비스 계약**으로 접근합니다. 상대 서비스 테이블을 직접 조인하거나 수정하지 않습니다.
- 서비스 간 Foreign Key 또는 운영 쿼리용 Cross-schema JOIN을 만들지 않습니다.
- Carelog 기존 `public` → `carelog` 스키마 이동과 운영 데이터 이전은 **별도 승인된 작업**입니다.

### IaC State / 실행 권한 (미구현)

Terraform 등을 도입한다면, **환경 × 소유 단위**로 상태와 실행 권한을 나눕니다.

| 환경 | Shared | Platform | Carelog | Finance |
| --- | --- | --- | --- | --- |
| dev | 독립 State·Role | 독립 State·Role | 독립 State·Role | 독립 State·Role |
| prod | 독립 State·Role | 독립 State·Role | 독립 State·Role | 독립 State·Role |

State Key와 Lock뿐 아니라 **IAM 적용 권한과 대상 리소스 범위까지 분리**해야 합니다. GitHub에서 변경된 파일 경로만 확인하는 Path Filter는 권한 격리 수단이 아닙니다.

State Backend 제공자·암호화·Lock 구성·OIDC/AssumeRole 설정·Secret 저장소는 **아직 선택하거나 구축하지 않았습니다.** 해당 구현은 C1/C2에서 별도 검토합니다.

## 7. CI/CD와 배포 트리거

| 변경 내용 | 자동 검증 대상 | 자동 운영 배포 |
| --- | --- | --- |
| Carelog 소스 PR | Carelog 빌드·테스트 | **없음** |
| Finance 소스 PR | Finance 빌드·테스트 | **없음** |
| Platform 소스 PR | Platform 회귀·필요한 호환성 확인 | **없음** |
| Infra Carelog 경로 변경 | Carelog 대상의 제한된 Infra Plan | **Apply 없음** |
| Infra Finance 경로 변경 | Finance 대상의 제한된 Infra Plan | **Apply 없음** |
| Infra Platform 경로 변경 | Platform 대상의 제한된 Infra Plan | **Apply 없음** |
| Infra Shared 경로 변경 | 공통 기반 Plan + Carelog/Finance 영향 확인 | **Apply 없음** |
| oh-my-ai 변경 | Skill·설치·로컬 기능 테스트 | 클라우드 배포 없음 |

위는 **후속 구현 시 적용할 정책**입니다. 현재 GitHub Actions가 위 표대로 실제 강제 작동한다고 주장하지 않습니다.

- PR/Source Merge와 Production 배포는 별도 승인으로 분리합니다.
- `main`에 Merge했다는 사실만으로 Production Deploy를 실행해서는 안 됩니다.
- GitHub 자체 Workflow 외에 **Webhook, 외부 CI/CD, 클라우드 배포 서비스 연결**까지 확인해야 합니다.
- GitHub Free Organization의 Private 저장소는 강제 Branch Rules 사용에 제약이 있을 수 있습니다. 사람의 수동 검증 절차와 GitHub의 기술적 강제 보호 기능을 동일하게 취급하지 않습니다.
- Rollback은 이미지 태그만 돌리는 작업이 아닙니다. **호환되는 이미지 Digest·설정·자격증명·DB 스키마 상태**를 함께 점검해야 합니다.
- **메시징 목표 정책:** ADR-0023/DEC-072에 따라 AWS SQS는 V1 서비스 간 비동기 메시징의 승인된 목표 Provider입니다. 다만 이 결정은 실제 Queue·DLQ·Worker·IAM 생성이나 서비스 연동이 완료됐다는 뜻이 아닙니다. 구현할 때 dev/prod Queue·DLQ·IAM을 분리하며, 리소스 생성·비용·배포는 별도 승인 Gate를 거칩니다.

## 8. Git 저장소 구조

목표 디렉터리(현재 전부 생성됐다는 뜻 아님):

```text
platform-infra/
├─ README.md
├─ docs/ownership-and-isolation.md
├─ environments/
│  ├─ dev/{shared,platform,carelog,finance}/
│  └─ prod/{shared,platform,carelog,finance}/
├─ modules/                 # 실제 재사용이 생긴 경우만
└─ .github/workflows/       # 후속 CI/CD 구현에서만
```

- `main`은 인프라 코드의 정본으로 유지합니다.
- 변경은 `feat/carelog-*`, `feat/finance-*`, `feat/platform-*`, `feat/shared-*` 같은 짧은 PR 브랜치를 사용합니다.
- `dev/prod`는 브랜치가 아니라 **독립 환경/State/권한/배포 대상**을 의미합니다.
- 어떤 제품의 코드 변경이라도 공통 자원을 무조건 재배포하도록 만들지 않습니다.

## 9. 실제 구현 전에 통과해야 할 검증

다음 표는 **완료된 테스트 목록이 아니라 미래의 검증 기준**입니다.

| ID | 검증 질문 | 통과 기준 | 현재 |
| --- | --- | --- | --- |
| ISO-01 | Carelog PR로 Finance가 빌드·배포·재시작되는가? | 실행되지 않아야 함 | NOT_RUN |
| ISO-02 | Finance Infra 권한으로 Carelog State·자원을 변경할 수 있는가? | 권한 거부 | NOT_RUN |
| ISO-03 | dev 권한으로 prod 자원·Secrets를 변경할 수 있는가? | 권한 거부 | NOT_RUN |
| ISO-04 | 공통 RDS/VPC 변경이 제품 영향 검토 없이 적용되는가? | 별도 승인 없이는 적용 금지 | NOT_RUN |
| ISO-05 | Identity 변경이 Carelog·Finance 동시 배포를 강제하는가? | 호환 기간 입증, 동시 배포 불필요 | NOT_RUN |
| ISO-06 | oh-my-ai V1이 클라우드 서비스 없이 동작하는가? | 독립 로컬 검증 PASS | NOT_RUN |
| ISO-07 | main 병합만으로 Production 배포가 발생하는가? | 자동 배포 없음이 확인돼야 함 | NOT_RUN |
| ISO-08 | Carelog Rollback이 Finance 이미지·Secrets·스키마도 바꾸는가? | Finance 불변 | NOT_RUN |
| ISO-09 | Path Filter만 우회하면 다른 서비스 State를 수정할 수 있는가? | IAM/State 경계에서 거부 | NOT_RUN |

**설계에 규칙이 적혀 있어도 실제 시스템에서 검증되기 전에는 PASS가 아닙니다.**

## 10. 작업 단계와 중단 조건

| 단계 | 산출물 | 허용 범위 |
| --- | --- | --- |
| **C0 — 현재** | README + 이 계약 문서 + 기존 ADR 대조·검토 | 문서만 |
| C1 — 다음 후보 | 최소 IaC 디렉터리, 정적 검사/No-op CI, State/IAM 구현 계획 | 별도 Owner 범위 승인 후 |
| C2 — 운영 후보 | AWS 자원, 실제 State Backend·IAM·Secrets·배포·복구 검증 | 별도 설계·비용·운영 승인 후 |

**이 계약은 다음 작업을 허용하지 않습니다:** Terraform `plan/apply/destroy` 실행, AWS 리소스 생성·수정, 운영 배포, DB Migration, 고객 데이터 접근, Carelog Cutover.

별도 메인 세션이 맡은 **Jira 필드 마이그레이션은 이 작업 범위에서 제외**합니다. RPL-116 모델·Fast 모드 정책도 Backlog만 유지하며 이 문서에서 구현하지 않습니다.

## 11. 근거 자료

- [ADR-0022 — AWS V1 MVP Primary Runtime](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0022-aws-v1-mvp-primary-runtime.md)
- [ADR-0023 — SQS 메시징·환경 격리 정책](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0023-sqs-messaging-and-environment-isolation.md)
- [ADR-0020 — PostgreSQL Schema Ownership](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0020-shared-platform-postgresql-schema-ownership.md)
- [AWS V1 MVP Deployment Plan](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/architecture/backend-service-foundation/aws-v1-mvp-deployment-plan.md)
- [Infra Issue #1 — 작업·검수 이력](https://github.com/ranikun-labs/platform-infra/issues/1)

공식 ADR와 충돌하는 사항이 생기면 이 문서를 근거로 즉시 인프라를 구현하지 않고, 변경된 정본과 Owner 결정을 먼저 재확인합니다.
