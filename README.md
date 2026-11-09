# Ranikun Labs 인프라 관리

> **한 줄 설명:** Carelog·Finance·공통 Platform이 각자 독립적으로 배포·복구되도록, 공용 클라우드 인프라와 제품별 운영 구성을 관리하는 저장소입니다.

**현재 단계: C0 — 인프라 설계 문서 정리. 실제 클라우드 환경은 만들지 않았습니다.**  
**작업 추적:** [Infra Issue #1](https://github.com/ranikun-labs/platform-infra/issues/1)

## 1. 왜 이 저장소가 필요한가?

Ranikun Labs에는 여러 제품이 있습니다.

- **Carelog:** 고객관리(CRM) 웹서비스
- **Finance Harness:** 금융 학습·저널·리뷰 웹서비스
- **Shared Platform:** Gateway·공통 인증(Identity)·Shared AI·Audit
- **oh-my-ai:** 개발자 컴퓨터에서 실행하는 로컬 AI 도구

각 서비스가 배포 환경을 제각각 정의하면 공통 네트워크·데이터베이스 구성은 중복되고, 반대로 모든 제품을 하나의 배포 작업으로 묶으면 한 제품을 수정할 때 다른 제품이 영향을 받습니다.

따라서 **인프라 코드는 한 저장소에서 관리하되, 변경·배포·복구 단위는 제품별로 분리**합니다.

**핵심 예시:** Carelog에 새로운 고객관리 기능을 배포해도 Finance를 다시 빌드하거나 재시작하거나 DB를 변경하면 안 됩니다. Finance를 배포할 때도 Carelog에는 영향을 주면 안 됩니다.

## 2. 무엇을 공유하고, 무엇을 분리하나?

| 대상 | 관리 방식 | 의미 |
| --- | --- | --- |
| 기본 네트워크(VPC 등) | 필요한 범위에서 공유 | 공통 기반 변경은 별도 영향 검토 |
| 물리 PostgreSQL RDS | 초기 목표에서는 공유 | 비용 절약 목적. **RDS 장애는 여러 제품에 영향을 줄 수 있음** |
| DB 스키마·계정·마이그레이션 | 서비스별 분리 | Carelog와 Finance가 상대방 데이터를 직접 수정하지 못하도록 권한·소유권 분리 |
| 서비스 실행 환경 | Gateway·Core·Carelog·Finance 개별 | 각각 배포·재시작·Rollback 가능 |
| 인프라 상태(Terraform State)·실행 권한 | 환경(dev/prod)과 서비스별 분리 | Carelog 인프라 작업이 Finance 자원을 변경할 수 없어야 함 |
| 비밀정보(Secrets)·IAM | 서비스별 최소 권한 | 공용 관리자 계정으로 제품 전체를 배포하지 않음 |
| CI/CD·릴리스 | 제품별 독립 | 한 제품의 PR/배포가 다른 제품의 배포를 자동 유발하지 않음 |

**주의:** 같은 RDS와 VPC를 사용하는 것은 물리적 장애까지 완전히 독립이라는 뜻이 아닙니다. 현재 목표는 **배포·변경·데이터 소유권의 분리**이며, 공통 자원의 장애 위험은 별도로 관리합니다.

## 3. 기존 소스 저장소와 책임을 나누는 방법

| 저장소 | 담당 |
| --- | --- |
| `carelog-be`, `carelog-fe` | Carelog 애플리케이션, Dockerfile, 로컬 실행·테스트 |
| `finance-harness-be`, `finance-harness-fe` | Finance 애플리케이션, Dockerfile, 로컬 실행·테스트 |
| `platform-services` | Gateway·Core 구현, 로컬 Compose, 통합 테스트 |
| **`platform-infra` (여기)** | 공유 클라우드 기반 및 제품별 배포 인프라의 구성·운영 계약 |
| `oh-my-ai` | 로컬 Skill·CLI·Hook 및 독립 릴리스. V1은 이 인프라에 의존하지 않음 |
| `harness-foundation-docs` | 서비스 경계·운영 방식의 공식 설계 결정(ADR) |

코드 변경에 필요한 Dockerfile이나 개발용 Compose를 모두 이 저장소로 옮기지 않습니다.

## 4. 기존 배치 그림 — 역사적 목표 기록, 현재 채택·구축 승인 아님

아래 그림은 2026-10-12 [ADR-0022](https://github.com/ranikun-labs/harness-foundation-docs/blob/cfc3ac80be777b2783bd60c249f745f77d7cb8b8/docs/adr/ADR-0022-aws-v1-mvp-primary-runtime.md)의 4 EC2 목표 기록입니다. 이 ADR은 `document_status: in_review`, `decision_status_scope: owner_policy_direction_only`이며 공식 문서 최종 승인·발효는 확인되지 않았습니다. 현행 AWS/ECS 방향과의 문구 정합화는 [RPL-125](https://ranikunlabs.atlassian.net/browse/RPL-125) 및 기존 Architecture Source Owner가 담당합니다. 이 C0 문서는 배치 방향을 다시 선택하거나 ECS/Aurora 수치·전환 방식을 결정하지 않습니다.

```text
AWS 서울 리전 (ap-northeast-2)
├─ Gateway 전용 EC2                ─┐
├─ Platform Core 전용 EC2          ─┤ 서비스별 독립 실행·배포
├─ Carelog Backend 전용 EC2        ─┤
└─ Finance Backend 전용 EC2        ─┘
                │
     공통 비공개 RDS PostgreSQL
     ├─ identity 스키마
     ├─ carelog 스키마
     ├─ finance 스키마
     └─ audit 스키마 (향후 승인 범위)
```

위 그림은 **역사적 목표 기록이며 현재 배치 채택·실제 EC2/RDS 생성·구축 승인 증거가 아닙니다.** 사양·DB 버전·복구·비용·보안 설정은 기존 승인 Gate와 후속 정합화·검증을 따릅니다.

## 5. 앞으로 이 저장소에 들어갈 구성

```text
platform-infra/
├─ README.md
├─ docs/
│  └─ ownership-and-isolation.md       # 독립 운영·소유권 계약
├─ environments/                       # 후속 단계에서만 생성
│  ├─ dev/
│  │  ├─ shared/  ├─ platform/  ├─ carelog/  └─ finance/
│  └─ prod/
│     ├─ shared/  ├─ platform/  ├─ carelog/  └─ finance/
└─ .github/workflows/                  # 검증된 CI/CD 설계 이후에만 생성
```

지금은 **README와 설계 계약만 존재**합니다. 표시된 `environments/` 등은 나중에 필요할 때 만드는 목표 디렉터리입니다.

Git은 `main` 하나를 정본으로 두고 작업별 짧은 브랜치/PR을 사용합니다. **dev·prod는 Git 브랜치가 아니라 독립 환경과 인프라 상태로 관리**합니다.

## 6. 작업 단계 및 승인

| 단계 | 해야 할 일 | 현재 |
| --- | --- | --- |
| **C0 설계** | 책임·독립성·변경·배포 금지 조건 문서화 및 검수 | 문서 작성 완료, 검토/채택 진행 중 |
| C1 구현 준비 | 최소 디렉터리, 검증 CI, IaC 구조의 PR 준비 | 미시작 |
| C2 실제 인프라 구축 | AWS·Terraform State·IAM·Secrets·서비스 배포 | **별도 Owner 승인 전 수행 금지** |

**이 문서를 GitHub에 병합하는 것은 인프라 생성/배포 승인이 아닙니다.** Terraform `apply/destroy`, AWS 리소스 변경, DB 마이그레이션, 운영 배포, Carelog Cutover는 각기 별도 승인 사항입니다.

## 7. 더 자세한 문서

- **[인프라 소유권·독립 운영 계약](docs/ownership-and-isolation.md)** — 구현 시 지켜야 하는 책임과 검증 항목
- [ADR-0022 — AWS V1 인프라 목표](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0022-aws-v1-mvp-primary-runtime.md)
- [ADR-0020 — PostgreSQL 스키마 소유권](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/adr/ADR-0020-shared-platform-postgresql-schema-ownership.md)
- [AWS V1 배포 설계](https://github.com/ranikun-labs/harness-foundation-docs/blob/main/docs/architecture/backend-service-foundation/aws-v1-mvp-deployment-plan.md)
