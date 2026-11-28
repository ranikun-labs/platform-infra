# 서울 DEV Carelog·Finance 배포 인계

상태: 배포 준비 중. 이 문서는 관찰과 다음 확인 사항을 인계하며 plan, apply, 마이그레이션 또는 배포 승인이나 현재 AWS 상태의 독립적인 증거가 아니다. 아래 내용은 `harness-foundation-docs/docs/handoffs/2026-11-28-seoul-dev-mvp-handoff.md`의 보고를 기준으로 한다. 실행 직전에 대상 계정·리전과 실제 상태를 다시 확인한다.

## 후보와 배포 입력

- [Terraform 후보 B `8651387`](https://github.com/ranikun-labs/platform-infra/commit/865138736fa38a18171cb566720a12e21ec587c6)의 세 루트는 Terraform 1.10.5 validate 3/3 통과로 보고됐다. 가입 ON 및 Finance 생성 plan은 **NOT_RUN**이다. validate는 plan이나 적용 결과를 뜻하지 않는다.
- 서울 ECR의 Core, 8443 TLS 프록시 및 trust-init 이미지 발행이 보고됐다. TLS 소스는 `1ad65fb3`이다. 프록시 빌드 중 Cloud 프록시 CA를 마운트했고 최종 이미지에는 포함하지 않았다는 발행 보고가 있다. 배포 전에 위 인계의 이미지 식별을 참고해 승인된 전체 digest와 대상 리전을 확인한다.
- Finance 전용 DB Secret과 Gateway↔Finance trusted-context Secret의 기존 참조는 새 세션의 AWS 메타데이터 및 Terraform 참조 조회에서 발견되지 않았다. 존재하지 않는다고 단정하지 않는다. DB 담당자와 배포 담당자는 DB URL 대상, 전용 계정·스키마 권한, Secret 참조 및 ECS 실행 역할 접근 권한을 정리하고 필요한 생성 승인을 받는다. 값은 문서나 Git에 기록하지 않는다.

## 배포 전 확인

1. 보존된 입력과 실제 상태를 대조하고 Carelog 단독 plan 가능 여부를 먼저 확인한다. Finance 서비스와 태스크 패밀리는 신규 생성으로 취급하고 별도의 롤백 기준을 정한다. Plan에서 기존 리소스의 교체·삭제, 영향 범위와 롤백 경로를 검토한다.
2. DB 담당자가 승인된 VPC 읽기 경로에서 실제 Flyway 이력을 확인한다. 소스 체크섬은 Core V3 `1006919839`, Carelog V9 `1045282328`, Finance V5 `882677658`로 보고됐지만 적용 증거는 아니다. 각 서비스의 스키마·역할과 마이그레이션 소유권을 확인하고 필요한 마이그레이션은 별도 승인한다.
3. Valkey TLS는 태스크 설정이 확인됐으나 실제 핸드셰이크는 확인되지 않았다. 승인된 경로에서 연결과 인증서 검증을 확인한다.
4. Worker·도메인·Gateway 연결 및 가입·로그인 요청 제한은 미확인이다. 실제 Worker 대상과 설정을 확인한다. MVP 검증은 두 제품의 가입·비밀번호 로그인, 데이터 저장과 새로고침 후 재조회 및 두 번째 계정의 접근 거부를 포함한다. Carelog는 고객·일정, Finance는 저널을 사용한다.

## 롤백과 승인 경계

이전 AWS 조회 보고의 기준은 Core 태스크 정의 `:3`, Gateway `:3`, Carelog `:6`, 그리고 구 Core를 위한 Carelog 8080 ingress다. 배포 전 이 기준과 해당 이미지·설정 및 복구 절차를 실제 상태에 대조한다. Finance는 신규 생성이므로 기존 태스크 정의로의 복귀를 가정하지 않고 제거 또는 복구 방법과 데이터 보존을 계획에서 명시한다. DB 변경의 복구는 서비스 롤백과 별도로 검토한다.

Plan, DB 및 Worker 확인을 진행한 뒤 결과와 영향·복구 경로를 검토하고 ECS·Worker 배포 및 필요한 화면 반영에 대한 승인을 받는다. Terraform apply, DB 마이그레이션, 배포 및 실제 AI 데이터 전송·저장은 각각 적절한 별도 승인 범위다. Carelog와 Finance의 배포·마이그레이션은 독립적으로 다루며 공유 변경의 소비자 호환성을 확인한다. 자격증명과 보호 입력은 승인된 비공개 경로로 관리한다.
