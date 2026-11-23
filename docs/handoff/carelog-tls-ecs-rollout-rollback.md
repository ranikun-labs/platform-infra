# Carelog TLS Task revision 반영·롤백 절차 (초안, 실행 전)

상태: **어떤 명령도 실행하지 않았다.** 모든 명령은 템플릿이고 `<PLACEHOLDER>`는 소유자 승인 후에만 채운다.
시크릿 값, `tfvars`, state, plan 원문, 환경변수 값은 채팅과 Git에 올리지 않는다.

## 식별자 (비밀 아님)

- 계정 124495093425, 리전 ap-northeast-2, 클러스터 `dev-shared`, 서비스·family·컨테이너 `ranikun-carelog-dev-api`
- 관찰 시점: desired 0, running 0, 서비스 revision `:6`(PRIMARY, COMPLETED), 서킷브레이커 rollback 켜짐
- **롤백 대상: `arn:aws:ecs:ap-northeast-2:124495093425:task-definition/ranikun-carelog-dev-api:6`**
- 롤백 기준 `:6`의 이미지 digest: `sha256:7dd7b858abb0fe701d2ac3a5c6cd25bfedea7efdc1a7f47fdc28362961561e54`
- revision `:1`~`:6`은 모두 ACTIVE이고 이미지 digest가 같다. `:7`은 없다(Terraform plan이 `:7`을 만들 수 있다. 아래 4번에서 번호를 다시 확인한다)

## 0. 중단 조건

다음 중 하나라도 해당하면 멈춘다.
- `aws sts get-caller-identity`의 계정이 124495093425가 아니거나 승인된 DEV 실행 역할이 아니다.
- 서비스가 ACTIVE가 아니거나 desired가 0이 아니거나 배포가 COMPLETED가 아니다.
- 같은 서비스를 다른 사람·릴리스·자동화가 바꾸고 있다(ECS에는 조건부 `update-service`가 없다. 단일 운영자만).
- 승인받은 plan과 다시 만든 plan의 주소·액션 표가 다르다.
- 후보 Task 정의에 `PLACEHOLDER`나 `SYNTHETIC` 값이 남아 있다.
- 적용할 Carelog 이미지 digest의 승인 기록이 없다(2026-11-23 기준 AWS와 저장소에서 찾지 못함).

## 1. 사전 조건 (이 작업에서 하지 않음)

1. 프록시 이미지를 private ECR 리포지토리에 digest 고정으로 올린다. 리포지토리가 아직 없다.
2. 서버 인증서와 개인키를 `TLS_CERT_PEM`·`TLS_KEY_PEM` 시크릿으로 승인된 소유자가 만든다. 형식(PEM 원문 또는 JSON 키)을 확인한 뒤 ARN 뒤에 `:key::` 접미사가 필요한지 정한다.
3. 이미지 선택:
   - 안 A: 새 digest `sha256:2630045e50b01879b0d3462fcd38509b9255131af52928e3a04878c6ade11d39`(승인 기록 미확보)
   - 안 B: `:6`의 digest 유지. enrollment 기능 지원 여부를 먼저 확인한다.
4. Flyway 가드 결정: 릴리스 워크플로는 `SPRING_FLYWAY_ENABLED=false`가 있어야 진행한다. 후보는 이를 추가하지 않는다. 추가하면 동작 변경이다.
5. IAM boundary: execution role boundary가 프록시 ECR, 인증서·키·enrollment 시크릿을 허용해야 한다. 인라인 정책만으로는 boundary가 막는다.

## 2. 후보 Task 정의 만들기 (`:6` 기반 병합)

Terraform baseline(`:1`)이 아니라 **현재 서비스 revision `:6`**에서 시작한다. `jq`가 필요하다.

```bash
export AWS_PROFILE=<APPROVED_DEV_PROFILE> AWS_REGION=ap-northeast-2
CLUSTER=dev-shared; SERVICE=ranikun-carelog-dev-api; FAMILY=ranikun-carelog-dev-api
PROXY_IMAGE="<ACCOUNT>.dkr.ecr.ap-northeast-2.amazonaws.com/<PROXY_REPO>@sha256:<DIGEST>"
CERT_ARN="<CERT_SECRET_ARN>"; KEY_ARN="<KEY_SECRET_ARN>"; ENROLL_ARN="<ENROLLMENT_SECRET_ARN>"

aws ecs describe-task-definition --task-definition "$FAMILY:6" --output json > <PRIVATE_DIR>/current-td.json

jq --arg app "$FAMILY" --arg img "$PROXY_IMAGE" --arg cert "$CERT_ARN" \
   --arg key "$KEY_ARN" --arg enroll "$ENROLL_ARN" '
  .taskDefinition
  | {family,taskRoleArn,executionRoleArn,networkMode,containerDefinitions,volumes,
     placementConstraints,requiresCompatibilities,cpu,memory,pidMode,ipcMode,
     proxyConfiguration,inferenceAccelerators,ephemeralStorage,runtimePlatform}
  | with_entries(select(.value != null))
  | .volumes += [{"name":"carelog-tls"}]
  | .containerDefinitions |= (
      map(if .name == $app then
            .portMappings = []
            | .environment = ((.environment | map(select(.name != "SERVER_ADDRESS" and .name != "CARELOG_IDENTITY_ENROLLMENT_ENABLED")))
                + [{"name":"SERVER_ADDRESS","value":"127.0.0.1"},
                   {"name":"CARELOG_IDENTITY_ENROLLMENT_ENABLED","value":"true"}])
            | .secrets = ((.secrets | map(select(.name != "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET")))
                + [{"name":"CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET","valueFrom":$enroll}])
          else . end)
      + [{
          "name":"carelog-tls-proxy","image":$img,"essential":true,
          "portMappings":[{"containerPort":8080,"protocol":"tcp"},{"containerPort":8443,"protocol":"tcp"}],
          "mountPoints":[{"sourceVolume":"carelog-tls","containerPath":"/run/carelog-tls","readOnly":false}],
          "secrets":[{"name":"TLS_CERT_PEM","valueFrom":$cert},{"name":"TLS_KEY_PEM","valueFrom":$key}],
          "logConfiguration":{"logDriver":"awslogs","options":{
            "awslogs-group":"/ecs/ranikun-carelog-dev-api","awslogs-region":"ap-northeast-2","awslogs-stream-prefix":"tls-proxy"}}
        }])
' <PRIVATE_DIR>/current-td.json > <PRIVATE_DIR>/carelog-td-candidate.json
```

안 A를 쓰면 앱 컨테이너의 `image`도 새 digest로 바꾼다. 프록시 컨테이너에는 `healthCheck` 추가를 검토한다(`nc` 존재 여부를 이미지에서 확인한다).

`:6`에서 그대로 가져와야 하는 항목: `config-tree` 볼륨과 `/run/secrets` 읽기 전용 마운트, `GATEWAY_INTERNAL_SECRET`, product-claims 참조, 앱 `healthCheck`(`startPeriod` 300). 후보 파일에서 확인한다.

```bash
F=<PRIVATE_DIR>/carelog-td-candidate.json
grep -c 'PLACEHOLDER\|SYNTHETIC' "$F"   # 0이어야 한다
jq '{vols:[.volumes[].name], ctrs:[.containerDefinitions[]|{n:.name,img:.image,sec:[.secrets[]?.name],mnt:[.mountPoints[]?.sourceVolume],ports:[.portMappings[]?.containerPort]}]}' "$F"
# 기대: vols = config-tree, carelog-tls / 앱 컨테이너 ports = [] / 앱 secrets 7개(:6의 6개 + enrollment)
```

## 3. IAM·SG 변경을 Terraform으로 먼저 적용 (승인된 plan만)

기대 plan: 8443 ingress 규칙 1개 추가, execution 인라인 정책 1개 update, Task 정의 새 revision 1개(교체). 이 단계 전에는 Task 정의 등록이 실패하거나 서비스 시작 때 시크릿·ECR 접근이 거부된다.

```bash
cd environments/dev/carelog
terraform init -input=false -backend-config='bucket=ranikun-dev-tfstate-124495093425' -backend-config='region=ap-northeast-2' -backend-config='allowed_account_ids=["124495093425"]'
terraform plan  -input=false -lock-timeout=5m -var-file='<PROTECTED_TLS_TFVARS>' -out='<SECURE_PLAN_PATH>'
scripts/plan-summary.sh '<SECURE_PLAN_PATH>' environments/dev/carelog   # 주소·액션만 출력
terraform apply '<SECURE_PLAN_PATH>'                                    # 승인된 동일 plan만
```

Terraform이 만드는 새 revision은 서비스에 연결되지 않는다(`task_definition`이 `ignore_changes`). 그래서 4번에서 등록하는 번호는 이 apply가 먼저 `:7`을 쓰면 `:8`이 된다. 번호를 가정하지 말고 반환된 ARN을 기록한다.

## 4. 후보 revision 등록

```bash
aws ecs register-task-definition --cli-input-json "file://<PRIVATE_DIR>/carelog-td-candidate.json" \
  --query 'taskDefinition.{arn:taskDefinitionArn,rev:revision}' --output json
# CANDIDATE_TD_ARN=<반환된 ARN>, CANDIDATE_REV=<번호> 를 기록한다
aws ecs describe-task-definition --task-definition "<CANDIDATE_TD_ARN>" \
  --query 'taskDefinition.{c:containerDefinitions[].name,v:volumes[].name}' --output json
```

## 5. 서비스에 반영 (desired 0 → 1, 한 번의 쓰기)

```bash
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].{status:status,desired:desiredCount,running:runningCount,td:taskDefinition,dep:deployments[].{s:status,r:rolloutState}}'
# ACTIVE, desired 0, running 0, td = :6, PRIMARY 배포 1개 COMPLETED 확인 후에만 진행

aws ecs update-service --cluster $CLUSTER --service $SERVICE \
  --task-definition "<CANDIDATE_TD_ARN>" --desired-count 1
aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE

aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,td:taskDefinition,dep:deployments[].{s:status,td:taskDefinition,r:rolloutState}}'
aws logs tail /ecs/ranikun-carelog-dev-api --since 10m     # app/…, tls-proxy/… 스트림
```

`--task-definition`과 `--desired-count`를 함께 넣는 이유: 새 배포가 시작돼야 서킷브레이커가 실패 시 이전 COMPLETED 배포(`:6`)로 되돌릴 수 있다. 서킷브레이커가 desired를 어떻게 되돌리는지는 확인하지 못했으므로 6번 수동 롤백을 바로 쓸 수 있게 준비한다.
검증: 배포 COMPLETED, running 1, Cloud Map 인스턴스 1개, Core에서 `<task-ip>:8443`(enrollment)과 `<task-ip>:8080`(claims 경로)에 도달, 8080에서 enrollment 403, 외부 로그인과 사용자 API 성공.

## 6. 롤백 (순서 고정)

1. 트래픽 중지와 이전 revision 복귀:
   ```bash
   aws ecs update-service --cluster $CLUSTER --service $SERVICE \
     --task-definition arn:aws:ecs:ap-northeast-2:124495093425:task-definition/ranikun-carelog-dev-api:6 --desired-count 0
   aws ecs wait services-stable --cluster $CLUSTER --services $SERVICE
   ```
   desired 0, running 0, td `:6`을 한 번의 `describe-services`로 확인한다.
2. 운영 기록에 남긴다: 롤백 대상 `:6`, 후보 revision 번호, 롤백 시각과 사유.
3. 8443 Core ingress 제거: Terraform에서 `enrollment_core_security_group_id = null`로 plan·검토·apply. 콘솔·CLI로 지우면 state가 어긋나므로 이후 맞춘다.
4. execution 인라인 정책을 TLS 항목 없는 보존 입력으로 되돌린다(plan에 정책 되돌림만 나와야 한다).
5. 후보 revision deregister는 릴리스 책임자 승인과 보존 기간이 지난 뒤에만 한다. **`:6`은 deregister하지 않는다.**
6. 인증서·키·enrollment 시크릿과 프록시 이미지는 이 변경 때문에 만든 것이고 참조가 없음을 확인한 뒤 복구 기간을 두고 정리한다.

데이터베이스 마이그레이션은 되돌려지지 않는다. 이 절차는 스키마를 바꾸지 않는다.

## 7. 이미지 릴리스 워크플로(`.github/workflows/dev-ecs-release.yml`)와의 관계

- 현재 서비스의 Task 정의를 읽어 **앱 컨테이너 이미지 필드만** 바꿔 새 revision을 등록하고 서비스를 갱신한다. 프록시·볼륨·시크릿은 현재 활성 revision에서 그대로 이어진다. 그래서 TLS revision이 먼저 서비스에 올라가 있어야 이후 이미지 릴리스가 그것을 계승한다.
- 시작 조건: desiredCount > 0, 배포 1개 COMPLETED, running == desired. 지금은 desired 0이라 시작할 수 없다. 처음 1로 올리는 것은 5번 수동 절차로 한다.
- 활성 앱 컨테이너에 `SPRING_FLYWAY_ENABLED=false`가 있어야 한다(1번 4항).
- 컨테이너 이름이 하나로 정해져야 한다. 사이드카가 있으면 `DEV_ECS_CONTAINER`가 앱 컨테이너를 정확히 가리키는지 확인한다.
- 자동 롤백은 DB를 복원하지 않는다.

## 8. Platform (Core·Gateway)

Core의 trust-init 컨테이너와 `carelog-trust` 볼륨 변경은 같은 방식으로 `:3`(Core) 기반 병합이 필요하다. 이번 범위에서는 plan까지만 확인했고 반영 절차는 만들지 않았다. Gateway는 cloudflared 컨테이너 2개를 포함한 현재 `:3` 구성을 보존한다.
