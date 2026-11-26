# DEV signup-off OFF plan 설정 런북

목적: `.github/workflows/dev-signup-off-plan.yml`이 기존 `ranikun-dev-shared-plan`을 빌려 쓰지 않고, 이 워크플로 전용 최소 권한 역할 `ranikun-dev-signup-off-plan`과 보호된 GitHub environment `dev-signup-off-plan`으로만 OFF plan을 실행하게 한다. 이 PR은 Terraform 정의와 설정 절차만 제공하며, IAM 적용·AWS 호출·허용 목록 추가는 포함하지 않는다.

## 1. 전제와 순서

1. 이 PR(역할 정의) 리뷰·병합 → 관리자가 IAM 적용(섹션 4) → GitHub environment 설정(섹션 3) → 워크플로 PR(`signup-off-plan-wf`) 병합 → 별도 승인 커밋으로 후보 SHA 허용 목록 추가.
2. 역할의 trust는 `job_workflow_ref`를 `main`의 워크플로로 고정한다. 워크플로 파일이 `main`에 있기 전에는 OIDC 교환이 실패하며, 이는 의도된 fail-closed다.
3. 허용 목록이 비어 있으면 `validate` 잡이 실패한다. 후보 SHA는 이 런북의 범위가 아니다.

## 2. GitHub environment 설정 (`dev-signup-off-plan`)

| 항목 | 값 |
|---|---|
| 이름 | `dev-signup-off-plan` (정확히 일치, 대소문자 포함) |
| Deployment branch 정책 | Selected branches, `main` 하나만 허용 |
| Required reviewers | DEV 플랜 승인 권한자 1명 이상 (사용자 또는 팀, 이름은 레포 밖 승인 명부에서 관리) |
| Prevent self-review | 켬 |
| Administrators bypass | 끔 (가능한 경우) |
| Wait timer | 0 |
| Environment secret | `DEV_SIGNUP_OFF_PRESERVE_JSON` (저장소 secret이 아니라 이 environment에만 둔다) |

`DEV_SIGNUP_OFF_PRESERVE_JSON`의 형태(값은 넣지 않는다):

```json
{
  "carelog":  { "<carelog 루트 변수명>": "...", "...": "..." },
  "platform": { "<platform 루트 변수명>": "...", "...": "..." },
  "finance":  { "<finance 루트 변수명>": "...", "...": "..." }
}
```

각 객체의 최상위 키는 해당 루트의 `dev-live-preserve.auto.tfvars.example` 최상위 키와 같아야 한다(이름만 기록):

- carelog: `region`, `aws_account_id`, `shared`, `gateway_security_group_id`, `service_name_override`, `preserve`, `runtime`, `tags`
- platform: `aws_region`, `aws_account_id`, `name_prefix`, `vpc_id`, `cluster_arn`, `namespace_id`, `namespace_name`, `private_subnet_ids`, `public_subnet_ids`, `enable_alb`, `certificate_arn`, `alb_ingress_cidrs`, `gateway_readiness_path`, `workload_public_ip`, `gateway_cloudflared`, `gateway_preserve`, `core_preserve`, `gateway_runtime`, `core_runtime`, `tags`
- finance: `region`, `aws_account_id`, `shared`, `gateway_security_group_id`, `runtime`, `tags`

규칙: 값은 실제 라이브 값(ARN, ID, digest)을 쓰고 placeholder를 넣지 않는다(워크플로가 `REPLACE`, `123456789012`, 0 digest를 거부한다). 값은 이 문서·PR·로그에 적지 않는다. 입력 JSON은 워크플로가 `::add-mask::`로 마스킹하지만, 관리자가 편집할 때도 화면 공유를 피한다.

## 3. IAM 적용 (관리자 전용, 이 세션 범위 밖)

- 누가: DEV 계정 관리자 중 별도로 권한을 받은 사람. 이 PR 작성자가 적용하지 않는다.
- 어디서: 병합된 `main` 체크아웃의 `environments/dev/signup-off-plan`.
- 사전 확인: 기존 GitHub OIDC provider(`arn:aws:iam::<계정>:oidc-provider/token.actions.githubusercontent.com`)가 존재하고 `sts.amazonaws.com` audience를 받는지 확인. 이 root는 provider를 만들지 않는다. 상태 버킷 `ranikun-dev-tfstate-124495093425`는 암호화와 S3 native locking이 확인된 상태여야 한다.

```bash
cd environments/dev/signup-off-plan
terraform init -input=false \
  -backend-config='bucket=ranikun-dev-tfstate-124495093425' \
  -backend-config='region=ap-northeast-2'
# 보호된 tfvars(저장소 밖 또는 gitignore)에 아래 값을 둔다.
#   aws_account_id, aws_region="ap-northeast-2", github_oidc_provider_arn,
#   state_bucket_name="ranikun-dev-tfstate-124495093425",
#   state_kms_key_arn (버킷 기본 암호화가 SSE-KMS일 때만), tags
terraform plan -input=false -var-file=<보호된 tfvars> -out=signup-off-plan.tfplan
# 계획에서 생성 대상이 역할·인라인 정책 2개뿐인지 확인한 뒤 관리자가 적용한다.
terraform apply signup-off-plan.tfplan
```

- 이 root의 state key는 `dev/signup-off-plan/terraform.tfstate`다. 워크플로 역할은 이 key를 읽을 수 없다.
- 기존 `ranikun-dev-shared-plan`과 `dev-shared-plan.yml`은 변경하지 않는다.

## 4. 검증

적용 후 관리자 권한 세션에서 확인한다. 아래 명령은 IAM 읽기·시뮬레이션만 사용한다.

```bash
ROLE=arn:aws:iam::124495093425:role/ranikun-dev-signup-off-plan
aws iam get-role --role-name ranikun-dev-signup-off-plan \
  --query 'Role.[MaxSessionDuration,AssumeRolePolicyDocument]'
# 기대: MaxSessionDuration=3600, sub/aud/job_workflow_ref 3개 조건 StringEquals

aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names s3:PutObject --resource-arns \
  arn:aws:s3:::ranikun-dev-tfstate-124495093425/dev/carelog/terraform.tfstate
# 기대: explicitDeny

aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names s3:PutObject s3:DeleteObject --resource-arns \
  arn:aws:s3:::ranikun-dev-tfstate-124495093425/dev/carelog/terraform.tfstate.tflock
# 기대: allowed

aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names s3:GetObject --resource-arns \
  arn:aws:s3:::ranikun-dev-tfstate-124495093425/dev/shared/terraform.tfstate
# 기대: implicitDeny (shared state는 읽을 수 없음)

aws iam simulate-principal-policy --policy-source-arn "$ROLE" \
  --action-names secretsmanager:GetSecretValue ecs:UpdateService --resource-arns '*'
# 기대: explicitDeny
```

워크플로 검증(허용 목록이 비어 있는 상태):

1. `workflow_dispatch`로 임의 40자 SHA를 입력하면 `validate`가 `Candidate allowlist is empty`로 실패해야 한다(플랜 잡 미실행, 자격 증명 미발급).
2. 역할 trust의 `job_workflow_ref`가 맞는지는 허용 목록 추가 후 첫 플랜 실행의 `Verify AWS identity` 단계로 확인한다.

허용 목록 추가 후 첫 실행에서 `AccessDenied`가 나오면 CloudTrail의 `ranikun-dev-signup-off-plan` 세션 이벤트에서 거부된 action만 보고 권한을 좁히거나 넓힌다. 넓히는 변경은 별도 PR로 리뷰한다.

## 5. 권한 표 (후보 B 기준 근거)

근거 커밋: `865138736fa38a18171cb566720a12e21ec587c6` (트리 `128364d0`). 경로는 그 커밋의 파일 기준 `file:line`이다. 루트는 carelog, platform, finance만 포함한다(release/shared 루트는 이 워크플로 범위 밖).

| 리소스 타입 | 근거 | 허용 action | 리소스 범위 |
|---|---|---|---|
| backend (state) | `environments/dev/*/versions.tf:9-12` | `s3:GetObject` | state key 3개 |
| backend (state) | 동일 | `s3:ListBucket` | 버킷, `s3:prefix` = state key 3개 + `.tflock` 3개 |
| backend (lock) | 동일 (`use_lockfile = true`) | `s3:PutObject`, `s3:DeleteObject` | `<key>.tflock` 3개만 |
| 상태 쓰기 금지 | — | explicit Deny `s3:PutObject*`, `s3:DeleteObject*`, `s3:RestoreObject` | state key 3개 |
| `aws_cloudwatch_log_group` | `modules/ecs-service/main.tf:36` | `logs:DescribeLogGroups` | `*` (listing) |
| 〃 | 〃 | `logs:ListTagsForResource` | `log-group:/ecs/dev-*`, `/ecs/ranikun-dev-*` |
| `aws_iam_role` (execution, app) | `modules/ecs-service/main.tf:41,47` | `iam:GetRole`, `iam:ListRoleTags` | `role/dev-*`, `role/ranikun-dev-*` |
| `aws_iam_role_policy` (execution, app) | `modules/ecs-service/main.tf:81,85` | `iam:GetRolePolicy` | 〃 |
| `aws_security_group` (service, alb) | `modules/ecs-service/main.tf:90`, `environments/dev/platform/ingress.tf:1` | `ec2:DescribeSecurityGroups` | `*` |
| `aws_vpc_security_group_ingress_rule` / `egress_rule` | `environments/dev/carelog/main.tf:108,118,130`, `environments/dev/finance/main.tf:50`, `environments/dev/platform/ingress.tf:9`, `environments/dev/platform/services.tf:160,168,176` | `ec2:DescribeSecurityGroupRules` | `*` |
| `aws_service_discovery_service` | `modules/ecs-service/main.tf:102` | `servicediscovery:GetService`, `servicediscovery:ListTagsForResource` | `service/*` |
| `aws_ecs_task_definition` | `modules/ecs-service/main.tf:118` | `ecs:DescribeTaskDefinition` | `*` (리소스 수준 권한 없음) |
| 〃 | 〃 | `ecs:ListTagsForResource` | `task-definition/dev-*:*`, `task-definition/ranikun-dev-*:*` |
| `aws_ecs_service` | `modules/ecs-service/main.tf:166` | `ecs:DescribeServices`, `ecs:ListTagsForResource` | `service/dev-shared/*` |
| `aws_lb`, `aws_lb_target_group`, `aws_lb_listener` | `environments/dev/platform/ingress.tf:18,27,57` | `elasticloadbalancing:DescribeLoadBalancers`, `DescribeLoadBalancerAttributes`, `DescribeTargetGroups`, `DescribeTargetGroupAttributes`, `DescribeListeners`, `DescribeListenerAttributes`, `DescribeTags` | `*` (Describe는 리소스 수준 없음) |
| `aws_sqs_queue` (audit, dlq), `aws_sqs_queue_redrive_allow_policy`, `aws_sqs_queue_policy` | `environments/dev/platform/audit-messaging.tf:27,33,43,123` | `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`, `sqs:ListQueueTags` | `*-audit`, `*-audit-dlq` |
| `aws_cloudwatch_metric_alarm` (dlq, age) | `environments/dev/platform/audit-messaging.tf:69,83` | `cloudwatch:DescribeAlarms`; `cloudwatch:ListTagsForResource` | `*` ; `alarm:*-audit-dlq-visible`, `alarm:*-audit-message-age` |
| `aws_iam_role_policy` (audit producer, consumer) | `environments/dev/platform/audit-messaging.tf:51,60` | `iam:GetRolePolicy` | `role/dev-*`, `role/ranikun-dev-*` (입력 역할명 확인 필요) |
| `data.aws_caller_identity` | `modules/ecs-service/main.tf:7` | 별도 IAM action 없음 (`sts:GetCallerIdentity`) | — |
| `data.aws_iam_policy_document` | 전 루트 | AWS 호출 없음 | — |
| 가드레일 explicit Deny | — | `secretsmanager:GetSecretValue`, `GetRandomPassword`, `ssm:GetParameter*`, `iam:PassRole`, `sts:AssumeRole*`, 생성·수정·삭제 action 계열 | `*` |

`aws:RequestedRegion = ap-northeast-2`는 리전 서비스 문장 전부에 걸었고, `aws:ResourceAccount = <계정>`은 ARN이 계정을 포함하는 IAM 문장에 걸었다. IAM은 전역 서비스라 `RequestedRegion`을 걸지 않았다.

## 6. 검증되지 않은 항목

- 버킷 기본 암호화 방식(SSE-S3 또는 SSE-KMS)은 이 세션에서 확인할 수 없다. SSE-KMS이면 `state_kms_key_arn`을 넣어야 한다. 그 경우 `kms:ViaService`로 제한된 decrypt/generate 문장이 추가된다.
- 버킷 소유 계정, 공개 차단, 버킷 정책은 레포에 정의가 없다. 관리자가 적용 전에 확인한다.
- 권한 표는 Terraform AWS provider 6.24.0 기준 추정이며 AWS 호출로 검증하지 않았다. provider 바이너리 해시는 lock 파일과 일치함을 확인했다. 실제 action 집합은 첫 플랜의 CloudTrail `AccessDenied`로 확인한다.
- platform audit producer/consumer 역할명은 입력값이다. `dev-` 또는 `ranikun-dev-`로 시작하지 않으면 해당 refresh가 거부된다.
- S3 backend가 락 충돌 진단을 위해 `.tflock`을 읽을 수 있다. 이 역할에는 `GetObject`를 주지 않았으므로 충돌 시 진단 메시지 대신 거부 오류가 나며, 실패 방향은 fail-closed다.
- `aws:ResourceAccount`는 S3 문장에 걸지 않았다. S3 버킷 소유 확인은 버킷 이름과 관리자 검증에 의존한다.
- 라이브 리소스와 실제 플랜 결과 비교는 이 세션에서 하지 않았다(AWS 호출 금지).

## 7. 롤백

- 워크플로 중단: 허용 목록을 비우는 커밋 또는 `dev-signup-off-plan` environment의 배포 권한을 제거한다.
- 역할 제거: 관리자가 `environments/dev/signup-off-plan`에서 `terraform destroy`를 실행한다(대상이 역할과 인라인 정책 2개뿐인지 확인). `ranikun-dev-shared-plan`에는 영향이 없다.
