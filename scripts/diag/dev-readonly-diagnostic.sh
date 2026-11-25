#!/usr/bin/env bash
# DEV 읽기 전용 진단. AWS 읽기 API만 호출한다. task definition 원문과 비밀값은 출력하지 않는다.
#   run       CI용: 자격 증명 검증 -> 읽기 수집 -> 마스킹 요약 -> $GITHUB_STEP_SUMMARY
#   selftest  합성 task definition으로 마스킹 필터와 리포트 렌더링을 검증한다 (AWS 호출 없음)
set -uo pipefail

ACCOUNT=124495093425
ROLE=ranikun-dev-shared-plan
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dev-diag.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
SUMMARY_OUT=${GITHUB_STEP_SUMMARY:-/dev/stdout}
DENIED=()
ERRORS=()

# 원문 task definition -> 마스킹 요약. 값은 허용목록 항목만 남기고, 나머지는 존재 여부(hints)만 남긴다.
read -r -d '' SANITIZE <<'JQ' || true
def flagname: test("(ENABLED|ENABLE|SIGNUP|DUAL_AUTH|_TLS)$");
def secretish: test("(^|_)(PASSWORD|PASSWD|SECRET|TOKEN|KEY|CREDENTIALS?|PRIVATE|PASS|JDBC|DSN)(_|$)");
def hostonly: sub("^[A-Za-z]+(:[A-Za-z]+)?://"; "") | sub("[/?#].*$"; "") | sub("^[^@]*@"; "");
def safe($n; $v):
  if ($v == null) then null
  elif ($n | secretish) then null
  elif ($n | flagname) then (if ($v | test("^(true|false)$")) then $v else "<비표준 값 생략>" end)
  elif $n == "SPRING_PROFILES_ACTIVE" then (if ($v | test("^[a-z0-9_,-]{1,64}$")) then $v else "<생략>" end)
  elif $n == "PORT" then (if ($v | test("^[0-9]{1,5}$")) then $v else "<생략>" end)
  elif ($n | test("(_URI|_URL)$")) then (if ($v | test("^[ -~]+$")) then ($v | hostonly) else "<생략>" end)
  else null end;
def secret_ref:
  (.valueFrom // "") as $r
  | ([$r | (capture("(?:secret:|parameter/)(?<n>[^:]+)")? | .n)] | .[0]) // ($r | split("/") | last);
def cont:
  {
    name: .name,
    image: (.image | split("@")[0]),
    digest: (if (.image | contains("@")) then (.image | split("@")[1]) else null end),
    env_files: ((.environmentFiles // []) | length),
    env: [ (.environment // [])[] | {name: .name, value: safe(.name; .value)} ],
    secrets: [ (.secrets // [])[] | {name: .name, ref: secret_ref} ],
    mounts: [ (.mountPoints // [])[] | {volume: .sourceVolume, path: .containerPath, ro: (.readOnly // false)} ],
    hints: {
      secrets_mount: any((.mountPoints // [])[]; (.containerPath // "") | startswith("/run/secrets")),
      rds_ca_mount: any((.mountPoints // [])[]; .containerPath == "/run/rds-ca.pem"),
      sslrootcert_env: any((.environment // [])[]; (.value // "") | test("sslrootcert"))
    }
  };
{
  family: .family,
  revision: .revision,
  volumes: [ (.volumes // [])[] | {name: .name, kind: (if .efsVolumeConfiguration then "efs" elif .host then "host" else "other" end)} ],
  containers: [ .containerDefinitions[]? | cont ]
}
JQ

# 마스킹 요약 -> Markdown 리포트. 요약 입력에 비밀값은 없다.
read -r -d '' EVAL <<'JQ' || true
def cs($re): [ .services[] | select(.service | test($re)) | .taskdef.containers[] ];
def denied($re): any(.denied[]?; test($re));
def vals($c; $re): [ $c[] | .env[] | select(.name | test($re)) | "\(.name)=\(.value // "(비공개)")" ];
def has($c; $re): ([ $c[] | .env[] | select(.name | test($re)) ] | length) > 0;
def secs($c; $re): [ $c[] | .secrets[] | select(.name | test($re)) | .name ];
def flagtrue($c; $re): any($c[] | .env[] | select(.name | test($re)); .value == "true");
def orna: if . == null or . == "" or . == [] then "없음" else . end;
def missing($c; $label; $ok):
  if ($c | length) == 0 then (if denied("^ecs:") then "권한 부족" else "누락 (\($label) 서비스 미발견)" end)
  elif $ok then "확인됨" else "누락" end;
def row($n; $item; $status; $ev): "| \($n) | \($item) | \($status) | \($ev) |";
"## DEV 읽기 전용 진단 (원문 비출력, 허용목록 값만 표시)",
"",
"| # | 항목 | 상태 | 근거 |",
"|---|---|---|---|",
(cs("carelog") as $c
  | row(1; "carelog /run/secrets 제공"; missing($c; "carelog"; any($c[]; .hints.secrets_mount));
      "마운트: \([ $c[] | .mounts[] | select(.path | startswith("/run/secrets")) | "\(.path)←\(.volume)" ] | join(", ") | orna) · secret 참조: \([ $c[] | .secrets[].name ] | join(", ") | orna)")),
(cs("carelog") as $c
  | row(2; "carelog /run/rds-ca.pem 또는 sslrootcert"; missing($c; "carelog"; any($c[]; .hints.rds_ca_mount or .hints.sslrootcert_env));
      "rds-ca 마운트=\(any($c[]; .hints.rds_ca_mount)) · sslrootcert 환경=\(any($c[]; .hints.sslrootcert_env))")),
(cs("core") as $c
  | row(3; "Core dev 프로파일·PLATFORM_IDENTITY_AUTH_ENABLED·FINANCE_REFERENCE_*";
      missing($c; "core"; has($c; "^SPRING_PROFILES_ACTIVE$") and has($c; "^PLATFORM_IDENTITY_AUTH_ENABLED$") and has($c; "^FINANCE_(REFERENCE|SIGNUP|DEV_DUAL)") and any($c[] | .env[] | select(.name == "SPRING_PROFILES_ACTIVE"); (.value // "") | test("dev")));
      (vals($c; "^(SPRING_PROFILES_ACTIVE|PLATFORM_IDENTITY_AUTH_ENABLED|FINANCE_)") | join(", ") | orna))),
(cs("gateway") as $g
  | row(4; "Gateway Finance 라우팅 (FINANCE_BE_URI·FINANCE_REFERENCE_ENABLED·trusted-context secret)";
      missing($g; "gateway"; has($g; "^FINANCE_BE_URI$") and has($g; "^FINANCE_REFERENCE_ENABLED$") and (secs($g; "TRUST|CONTEXT|FINANCE") | length > 0));
      (vals($g; "^(FINANCE_BE_URI|FINANCE_REFERENCE_ENABLED)$") + ["secret=\(secs($g; "TRUST|CONTEXT|FINANCE") | join(", ") | orna)"] | join(", ")))),
(cs("carelog") as $c
  | row(5; "Carelog CARELOG_IDENTITY_ENROLLMENT_ENABLED·CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED + secret 참조 (항목명 매칭 추정)";
      missing($c; "carelog"; has($c; "^CARELOG_IDENTITY_ENROLLMENT_ENABLED$") and has($c; "^CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED$") and (secs($c; "ENROLL") | length > 0) and (secs($c; "CLAIM|INTERNAL") | length > 0));
      (vals($c; "^CARELOG_(IDENTITY_ENROLLMENT|INTERNAL_IDENTITY_CLAIMS)_ENABLED$") + ["secret=\(secs($c; "ENROLL|CLAIM|INTERNAL") | join(", ") | orna)"] | join(", ")))),
(cs("carelog") as $c | cs("core") as $k | cs("gateway") as $g
  | (.elasticache // []) as $ec
  | row(6; "Valkey TLS: ElastiCache 전송 암호화 + 앱 플래그";
      (if ($ec | length) == 0 then (if denied("^elasticache:") then "권한 부족" else "누락 (replication group 미발견)" end)
       elif (any($ec[]; .transit_encryption == true) and flagtrue($c; "^VALKEY_TLS_ENABLED$") and (flagtrue($k; "^REDIS_TLS_ENABLED$") or flagtrue($g; "^REDIS_TLS_ENABLED$")))
         then "확인됨" else "누락" end);
      ("ElastiCache: \([ $ec[] | "\(.id) transit=\(.transit_encryption // "미확인")" ] | join(", ") | orna) · \((vals($c; "^VALKEY_TLS_ENABLED$") + vals($k; "^REDIS_TLS_ENABLED$") + vals($g; "^REDIS_TLS_ENABLED$")) | join(", ") | orna)"))),
(.rds.clusters // []) as $cl | (.rds.instances // []) as $ins
  | row(7; "RDS force_ssl·CA 식별자";
      (if ($cl | length) == 0 then (if denied("^rds:") then "권한 부족" else "누락 (dev Aurora 클러스터 미발견)" end)
       elif all($cl[]; (.force_ssl == "1" or .force_ssl == "true" or .force_ssl == 1)) then "확인됨" else "누락" end);
      ([ $cl[] as $x | "\($x.id): force_ssl=\($x.force_ssl // "미확인") · CA=\([ $ins[] | select(.cluster == $x.id) | .ca ] | unique | join("/") | orna)" ] | join("; ") | orna)),
row(8; "Core V3 / Carelog V9"; "미확정"; "DB 조회 경로 없음 — 이 진단은 DB에 연결하지 않음"),
"",
"### 권한 부족 (필요 IAM 액션)",
(if (.denied | length) == 0 then "- 없음" else (.denied | map("- 권한 부족: " + .) | join("\n")) end),
"",
"### 기타 오류",
(if (.errors | length) == 0 then "- 없음" else (.errors | map("- " + .) | join("\n")) end)
JQ

# AWS 읽기 호출 래퍼. 실패 시 AccessDenied는 DENIED에, 그 외는 ERRORS에 코드만 기록하고 계속 진행한다.
# stderr 원문은 로그에 출력하지 않는다.
call() { # <label> <iam-action> <resource> <cmd...>
  local label=${1//[^A-Za-z0-9_-]/_} action=$2 res=$3
  shift 3
  local out="$WORK/$label.json" err="$WORK/$label.err"
  if "$@" >"$out" 2>"$err"; then
    return 0
  fi
  if grep -qE 'AccessDenied|UnauthorizedOperation|not authorized' "$err"; then
    DENIED+=("$action on $res")
  else
    local code
    code=$(sed -n 's/.*An error occurred (\([A-Za-z.]*\)).*/\1/p' "$err" | head -1)
    ERRORS+=("$label: ${code:-UnknownError}")
  fi
  return 1
}

# 입력이 없거나 파싱되지 않으면 [] 를 남긴다.
extract() { # <jq-filter> <input> <output>
  if [[ -s $2 ]] && jq -c "$1" "$2" >"$3" 2>/dev/null && [[ -s $3 ]]; then
    :
  else
    echo '[]' >"$3"
  fi
}

run() {
  local acct arn
  if aws sts get-caller-identity --output json >"$WORK/id.json" 2>/dev/null; then
    acct=$(jq -r '.Account // empty' "$WORK/id.json")
    arn=$(jq -r '.Arn // empty' "$WORK/id.json")
  fi
  if [[ "${acct:-}" != "$ACCOUNT" || "${arn:-}" != "arn:aws:sts::$ACCOUNT:assumed-role/$ROLE/"* ]]; then
    printf '## DEV 읽기 전용 진단\n\n자격 증명 검증 실패: 계정 또는 assumed-role 불일치. 읽기 수집을 중단했다.\n' >>"$SUMMARY_OUT"
    echo 'identity check failed' >&2
    exit 1
  fi

  # ECS: dev 클러스터의 gateway/core/carelog/finance 서비스와 task definition
  local arn_c cname i sname tdarn cl n=0
  local -a clusters sarns
  call ecs-clusters ecs:ListClusters 'cluster(*)' aws ecs list-clusters --output json || true
  if [[ -s $WORK/ecs-clusters.json ]]; then
    mapfile -t clusters < <(jq -r '.clusterArns[]? | select(test("dev"))' "$WORK/ecs-clusters.json")
  fi
  : >"$WORK/svc.tsv"
  for arn_c in "${clusters[@]:-}"; do
    [[ -n $arn_c ]] || continue
    cname=${arn_c##*/}
    call "ecs-list-$cname" ecs:ListServices "cluster $cname" aws ecs list-services --cluster "$arn_c" --max-results 100 --output json || continue
    mapfile -t sarns < <(jq -r '.serviceArns[]?' "$WORK/ecs-list-$cname.json")
    for ((i = 0; i < ${#sarns[@]}; i += 10)); do
      call "ecs-desc-$cname-$i" ecs:DescribeServices "cluster $cname" aws ecs describe-services --cluster "$arn_c" --services "${sarns[@]:i:10}" --output json || continue
      jq -r --arg c "$cname" '.services[]? | select(.serviceName | test("gateway|core|carelog|finance")) | [$c, .serviceName, .taskDefinition] | @tsv' "$WORK/ecs-desc-$cname-$i.json" >>"$WORK/svc.tsv"
    done
  done

  : >"$WORK/services.ndjson"
  while IFS=$'\t' read -r cl sname tdarn; do
    n=$((n + 1))
    if call "td-$n" ecs:DescribeTaskDefinition "$tdarn" aws ecs describe-task-definition --task-definition "$tdarn" --output json; then
      jq -c '.taskDefinition // empty' "$WORK/td-$n.json" | jq -c "$SANITIZE" \
        | jq -c --arg c "$cl" --arg s "$sname" '{cluster: $c, service: $s, taskdef: .}' >>"$WORK/services.ndjson"
    fi
  done < "$WORK/svc.tsv"

  # ElastiCache: 전송 암호화 설정만 확인
  call ec-rg elasticache:DescribeReplicationGroups 'elasticache(*)' aws elasticache describe-replication-groups --output json || true
  call ec-sc elasticache:DescribeServerlessCaches 'elasticache(*)' aws elasticache describe-serverless-caches --output json || true
  extract '[.ReplicationGroups[]? | select(.ReplicationGroupId | test("dev")) | {id: .ReplicationGroupId, transit_encryption: (.TransitEncryptionEnabled // null), status: .Status}]' "$WORK/ec-rg.json" "$WORK/ec1.json"
  extract '[.ServerlessCaches[]? | select(.ServerlessCacheName | test("dev")) | {id: .ServerlessCacheName, transit_encryption: (.TransitEncryptionEnabled // null), status: .Status}]' "$WORK/ec-sc.json" "$WORK/ec2.json"

  # RDS: 클러스터 목록, 클러스터 파라미터 rds.force_ssl (읽기), 인스턴스 CA
  call rds-clusters rds:DescribeDBClusters 'rds(*)' aws rds describe-db-clusters --output json || true
  call rds-instances rds:DescribeDBInstances 'rds(*)' aws rds describe-db-instances --output json || true
  extract '[.DBClusters[]? | select(.DBClusterIdentifier | test("dev")) | {id: .DBClusterIdentifier, engine: .Engine, pg: .DBClusterParameterGroup}]' "$WORK/rds-clusters.json" "$WORK/rdsc.json"
  extract '[.DBInstances[]? | select(.DBClusterIdentifier != null) | {cluster: .DBClusterIdentifier, ca: .CACertificateIdentifier}]' "$WORK/rds-instances.json" "$WORK/rdsi.json"
  : >"$WORK/rdsc.ndjson"
  local row pg id fs lbl
  while IFS= read -r row; do
    pg=$(jq -r '.pg // empty' <<<"$row")
    id=$(jq -r '.id' <<<"$row")
    lbl="rds-params-${id//[^A-Za-z0-9_-]/_}"
    fs=null
    if [[ -n $pg ]] && call "$lbl" rds:DescribeDBClusterParameters "cluster-parameter-group $pg" aws rds describe-db-cluster-parameters \
        --db-cluster-parameter-group-name "$pg" \
        --query "Parameters[?ParameterName=='rds.force_ssl'].ParameterValue | [0]" --output json; then
      fs=$(jq -c . "$WORK/$lbl.json" 2>/dev/null)
      [[ -n $fs ]] || fs=null
    fi
    jq -c --argjson fs "$fs" '. + {force_ssl: $fs}' <<<"$row" >>"$WORK/rdsc.ndjson"
  done < <(jq -c '.[]' "$WORK/rdsc.json")

  # 요약 조립 (원문 없음)
  jq -s '.' "$WORK/services.ndjson" >"$WORK/services.json"
  jq -s '.' "$WORK/rdsc.ndjson" >"$WORK/rdsc.final.json"
  jq -s 'add' "$WORK/ec1.json" "$WORK/ec2.json" >"$WORK/ec.json"
  printf '%s\n' "${DENIED[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))' >"$WORK/denied.json"
  printf '%s\n' "${ERRORS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))' >"$WORK/errors.json"
  jq -n \
    --argjson services "$(cat "$WORK/services.json")" \
    --argjson ec "$(cat "$WORK/ec.json")" \
    --argjson clusters "$(cat "$WORK/rdsc.final.json")" \
    --argjson instances "$(cat "$WORK/rdsi.json")" \
    --argjson denied "$(cat "$WORK/denied.json")" \
    --argjson errors "$(cat "$WORK/errors.json")" \
    '{services: $services, elasticache: $ec, rds: {clusters: $clusters, instances: $instances}, denied: $denied, errors: $errors}' \
    >"$WORK/summary.json"
  jq -r "$EVAL" "$WORK/summary.json" >>"$SUMMARY_OUT"
  echo 'DEV read-only diagnostic: summary written (raw task definitions not printed).'
}

selftest() {
  local fails=0 fx="$WORK/fixture.json" san="$WORK/san.json" sum="$WORK/sum.json" rep="$WORK/report.md" all="$WORK/all.out"
  # 합성 task definition: FAKE-SECRET-* 는 출력에 나오면 안 된다.
  cat >"$fx" <<'JSON'
{"taskDefinition":{"family":"dev-carelog","revision":7,
 "containerDefinitions":[{"name":"carelog",
  "image":"124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/carelog-be:1.2.3@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "environment":[
    {"name":"SPRING_PROFILES_ACTIVE","value":"prod"},
    {"name":"VALKEY_TLS_ENABLED","value":"true"},
    {"name":"CARELOG_IDENTITY_ENROLLMENT_ENABLED","value":"FAKE-SECRET-XYZ"},
    {"name":"DB_PASSWORD","value":"FAKE-SECRET-123"},
    {"name":"SPRING_DATASOURCE_URL","value":"jdbc:postgresql://db.internal.example:5432/carelog?sslrootcert=/run/rds-ca.pem&password=FAKE-SECRET-URL"},
    {"name":"FINANCE_BE_URI","value":"https://user:FAKE-SECRET-URI@finance-be.internal:8080/path"}],
  "secrets":[{"name":"ENROLLMENT_TRUST_KEY","valueFrom":"arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:dev/carelog/enrollment-AbCdEf:key::"}],
  "mountPoints":[{"sourceVolume":"secrets","containerPath":"/run/secrets","readOnly":true}]}],
 "volumes":[{"name":"secrets","host":{"sourcePath":"/x"}}]}}
JSON
  jq '.taskDefinition' "$fx" | jq -c "$SANITIZE" >"$san" || fails=$((fails + 1))
  grep -q 'finance-be.internal:8080' "$san" || { echo 'FAIL: hostname extraction' >&2; fails=$((fails + 1)); }
  grep -q '비표준 값 생략' "$san" || { echo 'FAIL: non-boolean flag not masked' >&2; fails=$((fails + 1)); }
  grep -q 'dev/carelog/enrollment-AbCdEf' "$san" || { echo 'FAIL: secret ref name' >&2; fails=$((fails + 1)); }
  # 합성 요약 (core/gateway 포함) -> 리포트
  jq -n --slurpfile td "$san" '{
    services: [
      {cluster: "dev-shared", service: "dev-carelog", taskdef: $td[0]},
      {cluster: "dev-shared", service: "dev-core", taskdef: {containers: [{name: "core", env: [
        {name: "SPRING_PROFILES_ACTIVE", value: "dev"}, {name: "PLATFORM_IDENTITY_AUTH_ENABLED", value: "true"},
        {name: "FINANCE_REFERENCE_ENABLED", value: "true"}, {name: "FINANCE_DEV_DUAL_AUTH", value: "true"},
        {name: "REDIS_TLS_ENABLED", value: "true"}, {name: "DB_PASSWORD", value: null}], secrets: [], mounts: [], hints: {}}]}},
      {cluster: "dev-shared", service: "dev-gateway", taskdef: {containers: [{name: "gw", env: [
        {name: "FINANCE_BE_URI", value: "finance-be.internal:8080"}, {name: "FINANCE_REFERENCE_ENABLED", value: "true"},
        {name: "REDIS_TLS_ENABLED", value: "true"}], secrets: [{name: "TRUSTED_CONTEXT_KEY", ref: "dev/gw/trust"}], mounts: [], hints: {}}]}}
    ],
    elasticache: [{id: "dev-shared-valkey", transit_encryption: true, status: "available"}],
    rds: {clusters: [{id: "dev-shared-database", engine: "aurora-postgresql", force_ssl: "1"}],
          instances: [{cluster: "dev-shared-database", ca: "rds-ca-rsa2048-g1"}]},
    denied: ["ecs:ListServices on cluster x"], errors: []}' >"$sum" || fails=$((fails + 1))
  jq -r "$EVAL" "$sum" >"$rep" || fails=$((fails + 1))
  cat "$san" "$rep" >"$all"
  grep -q 'FAKE' "$all" && { echo 'FAIL: fake secret leaked into output' >&2; fails=$((fails + 1)); }
  grep -q '| 1 | carelog /run/secrets 제공 | 확인됨' "$rep" || { echo 'FAIL: row 1 status' >&2; fails=$((fails + 1)); }
  grep -q '| 6 | Valkey TLS.* | 확인됨' "$rep" || { echo 'FAIL: row 6 status' >&2; fails=$((fails + 1)); }
  grep -q '| 8 | Core V3 / Carelog V9 | 미확정' "$rep" || { echo 'FAIL: row 8' >&2; fails=$((fails + 1)); }
  grep -q '권한 부족: ecs:ListServices' "$rep" || { echo 'FAIL: denied list' >&2; fails=$((fails + 1)); }
  if (( fails )); then
    cat "$rep" >&2
    echo "selftest FAILED ($fails)" >&2
    exit 1
  fi
  cat "$rep"
  echo 'selftest OK: 비밀 문자열 미출력 확인'
}

case ${1:-} in
  run) run ;;
  selftest) selftest ;;
  *) echo "usage: $0 run|selftest" >&2; exit 2 ;;
esac
