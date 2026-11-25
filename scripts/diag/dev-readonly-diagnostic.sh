#!/usr/bin/env bash
# DEV 읽기 전용 진단. AWS 읽기 API만 호출한다. task definition 원문과 비밀값은 출력하지 않는다.
#   run       CI용: 자격 증명 검증 -> 읽기 수집 -> 마스킹 요약 -> $GITHUB_STEP_SUMMARY
#   selftest  합성 데이터로 마스킹 필터, 판정 규칙, 파싱 실패 처리를 검증한다 (AWS 호출 없음)
# 이름 기준: platform-services 실제 바인딩 이름(gateway-app/platform-core application.yml)만 인정한다.
#            레거시 이름(예: FINANCE_REFERENCE_ENABLED)은 alias가 없으므로 없는 값으로 취급한다.
# 판정 원칙: 명시 값(false, 마운트 부재, 비정상 mode)만 확정 근거로 쓴다.
#           environmentFiles가 있는 서비스에서 "미설정"으로 보이는 항목은 부분 확인으로 낮춘다.
set -uo pipefail

ACCOUNT=124495093425
ROLE=ranikun-dev-shared-plan
WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dev-diag.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT
SUMMARY_OUT=${GITHUB_STEP_SUMMARY:-/dev/stdout}
DENIED=()
ERRORS=()

# 원문 task definition -> 마스킹 요약. 값은 허용목록 이름의 값만 남기고, 나머지 env 이름은 버린다.
# 허용목록: 비밀이 아닌 플래그·URI·프로파일 이름만 (실제 바인딩 이름, 위 주석 참조).
read -r -d '' SANITIZE <<'JQ' || true
def allowed: test("^(SPRING_PROFILES_ACTIVE"
  + "|VALKEY_TLS_ENABLED|CARELOG_IDENTITY_ENROLLMENT_ENABLED|CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED"
  + "|PLATFORM_IDENTITY_AUTH_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED"
  + "|PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED"
  + "|PLATFORM_IDENTITY_REDIS_TLS_ENABLED"
  + "|PLATFORM_GATEWAY_FINANCE_BE_URI|PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED"
  + "|PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED|PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED"
  + "|PLATFORM_GATEWAY_REDIS_TLS_ENABLED)$");
def flagname: test("(ENABLED|ENABLE|SIGNUP|DUAL_AUTH|_TLS)$");
def secretish: test("(^|_)(PASSWORD|PASSWD|SECRET|TOKEN|KEY|CREDENTIALS?|PRIVATE|PASS|JDBC|DSN)(_|$)");
# URL -> host[:port]. 마지막 '@' 뒤만 취해 userinfo를 버리고, 호스트 문자 집합에 맞지 않으면 <생략>으로 닫는다(fail-closed).
def hostonly:
  sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "")
  | (if contains("@") then split("@") | last else . end)
  | sub("[/?#].*$"; "")
  | if test("^[A-Za-z0-9.-]+(:[0-9]{1,5})?$") then . else "<생략>" end;
def safe($n; $v):
  if ($v == null) then null
  elif ($n | secretish) then null
  elif ($n | flagname) then (if ($v | test("^(?i)(true|false)$")) then $v else "<비표준 값 생략>" end)
  elif $n == "SPRING_PROFILES_ACTIVE" then (if ($v | test("^[a-z0-9_,-]{1,64}$")) then $v else "<생략>" end)
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
    env: [ (.environment // [])[] | select(.name | allowed) | {name: .name, value: safe(.name; .value)} ],
    secrets: [ (.secrets // [])[] | {name: .name, ref: secret_ref} ],
    mounts: [ (.mountPoints // [])[] | {volume: .sourceVolume, path: .containerPath, ro: (.readOnly // false)} ],
    hints: {
      secrets_mount: any((.mountPoints // [])[]; (.containerPath // "") | (. == "/run/secrets" or startswith("/run/secrets/"))),
      rds_ca_mount: any((.mountPoints // [])[]; .containerPath == "/run/rds-ca.pem"),
      sslrootcert_env: any((.environment // [])[]; (.value // "") | test("sslrootcert"; "i")),
      sslrootcert_rds_ca: any((.environment // [])[]; (.value // "") | test("(^|[?&;\\s])sslrootcert=/run/rds-ca\\.pem($|[&;\\s])"))
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
def cs($re): [ .services[]? | select(.service | test($re; "i")) | .taskdef.containers[]? ];
def pf($re): any(.services[]? | select(.service | test($re; "i")) | (.parse_failed // false); .);
def ff($re): any(.services[]? | select(.service | test($re; "i")) | (.fetch_failed // false); .);
def denied($re): any(.denied[]?; test($re));
def vals($c; $re): [ $c[] | .env[] | select(.name | test($re)) | "\(.name)=\(.value // "(비공개)")" ];
def has($c; $re): ([ $c[] | .env[] | select(.name | test($re)) ] | length) > 0;
def hassec($c; $n): any($c[] | .secrets[]?; .name == $n);
def secs($c; $re): [ $c[] | .secrets[]? | select(.name | test($re)) | .name ];
# 값 비교는 대소문자 무시. "true"만 참이다.
def flagtrue($c; $re): any($c[] | .env[] | select(.name | test($re)); ((.value // "") | ascii_downcase) == "true");
# 명시된 값이 true가 아닌 플래그 = 확정 근거 (예: "PLATFORM_IDENTITY_AUTH_ENABLED 값=false")
def flagbad($c; $re): [ $c[] | .env[] | select(.name | test($re)) | select(((.value // "") | ascii_downcase) != "true") | "\(.name) 값=\(.value // "미설정")" ];
# SPRING_PROFILES_ACTIVE를 쉼표로 나눈 항목 중 정확히 "dev"가 있어야 한다.
def profdev($c): any($c[] | .env[] | select(.name == "SPRING_PROFILES_ACTIVE") | (.value // "") | split(",")[]; . == "dev");
def profbad($c): if profdev($c) then [] else [ $c[] | .env[] | select(.name == "SPRING_PROFILES_ACTIVE") | "SPRING_PROFILES_ACTIVE 값=\(.value // "미설정")" ] end;
def efiles($c): any($c[]; (.env_files // 0) > 0);
def orna: if . == null or . == "" or . == [] then "없음" else . end;
# $why: 확정 근거 목록. 비어 있고 environmentFiles가 있으면 부분 확인으로 낮춘다.
def verdict($label; $c; $ok; $why):
  if ($c | length) == 0 then
    (if denied("^ecs:") then "권한 부족"
     elif pf($label) then "판정 불가(파싱 실패)"
     elif ff($label) then "판정 불가(조회 실패)"
     else "누락 (\($label) 서비스 미발견)" end)
  elif $ok then "확인됨"
  elif ($why | length) > 0 then "누락 (\($why | join(", ")))"
  elif efiles($c) then "부분 확인(environmentFiles 미열람)"
  else "누락" end;
def row($n; $item; $status; $ev): "| \($n) | \($item) | \($status) | \($ev) |";
"## DEV 읽기 전용 진단 (원문 비출력, 허용목록 값만 표시)",
"",
"| # | 항목 | 상태 | 근거 |",
"|---|---|---|---|",
(cs("carelog") as $c
  | row(1; "carelog /run/secrets 마운트 존재";
      verdict("carelog"; $c; any($c[]; .hints.secrets_mount); []);
      "마운트: \([ $c[] | .mounts[] | select(.path | (. == "/run/secrets" or startswith("/run/secrets/"))) | "\(.path)←\(.volume)" ] | join(", ") | orna) · secret 참조: \([ $c[] | .secrets[].name ] | join(", ") | orna) · 파일 내용 미확인")),
(cs("carelog") as $c
  | row(2; "carelog sslrootcert=/run/rds-ca.pem + /run/rds-ca.pem 마운트";
      verdict("carelog"; $c;
        any($c[]; .hints.sslrootcert_rds_ca) and any($c[]; .hints.rds_ca_mount);
        ((if any($c[]; .hints.sslrootcert_env) and (any($c[]; .hints.sslrootcert_rds_ca) | not) then ["sslrootcert≠/run/rds-ca.pem"] else [] end)
         + (if any($c[]; .hints.rds_ca_mount) then [] else ["/run/rds-ca.pem 마운트 없음"] end)));
      "sslrootcert=/run/rds-ca.pem 일치=\(any($c[]; .hints.sslrootcert_rds_ca)) · sslrootcert 항목=\(any($c[]; .hints.sslrootcert_env)) · rds-ca 마운트=\(any($c[]; .hints.rds_ca_mount))")),
(cs("core") as $c
  | row(3; "Core dev 프로파일·PLATFORM_IDENTITY_AUTH_ENABLED·FINANCE_REFERENCE/SIGNUP/DEV_DUAL_AUTH·core secret";
      verdict("core"; $c;
        profdev($c)
          and flagtrue($c; "^PLATFORM_IDENTITY_AUTH_ENABLED$")
          and flagtrue($c; "^PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED$")
          and flagtrue($c; "^PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED$")
          and flagtrue($c; "^PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED$")
          and hassec($c; "PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL")
          and hassec($c; "PLATFORM_IDENTITY_PRODUCT_CLAIMS_SERVICE_SECRET");
        (profbad($c) + flagbad($c; "^(PLATFORM_IDENTITY_AUTH_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED)$")));
      "env: \(vals($c; "^(SPRING_PROFILES_ACTIVE|PLATFORM_IDENTITY_AUTH_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED|PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED)$") | join(", ") | orna) · secret: \(secs($c; "^PLATFORM_IDENTITY_(CARELOG_ENROLLMENT_CREDENTIAL|PRODUCT_CLAIMS_SERVICE_SECRET)$") | join(", ") | orna)")),
(cs("gateway") as $g
  | row(4; "Gateway Finance 라우팅 (PLATFORM_GATEWAY_FINANCE_BE_URI·REFERENCE/TRUSTED_CONTEXT 플래그·trusted-context secret)";
      verdict("gateway"; $g;
        has($g; "^PLATFORM_GATEWAY_FINANCE_BE_URI$")
          and flagtrue($g; "^PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED$")
          and flagtrue($g; "^PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED$")
          and hassec($g; "PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET");
        flagbad($g; "^(PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED|PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED)$"));
      "\(vals($g; "^(PLATFORM_GATEWAY_FINANCE_BE_URI|PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED|PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED|PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED)$") | join(", ") | orna) · secret=\(secs($g; "^PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET$") | join(", ") | orna)")),
(cs("carelog") as $c
  | row(5; "Carelog 내부 identity 플래그 + secret (정확한 이름 매칭)";
      verdict("carelog"; $c;
        flagtrue($c; "^CARELOG_IDENTITY_ENROLLMENT_ENABLED$") and flagtrue($c; "^CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED$")
          and hassec($c; "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET") and hassec($c; "CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET");
        flagbad($c; "^CARELOG_(IDENTITY_ENROLLMENT|INTERNAL_IDENTITY_CLAIMS)_ENABLED$"));
      (vals($c; "^CARELOG_(IDENTITY_ENROLLMENT|INTERNAL_IDENTITY_CLAIMS)_ENABLED$") + ["secret=\(secs($c; "^CARELOG_(IDENTITY_ENROLLMENT|INTERNAL_IDENTITY_CLAIMS)_SERVICE_SECRET$") | join(", ") | orna)"] | join(", ")))),
(cs("carelog") as $c | cs("core") as $k | cs("gateway") as $g
  | (.elasticache // []) as $ec
  | [ $ec[] | select(.kind == "replication-group") ] as $rg
  | [ $ec[] | select(.kind == "serverless") ] as $sl
  | ((any($rg[]; .transit_encryption == true and .mode == "required")) or (($sl | length) > 0)) as $transit
  | ($transit and flagtrue($c; "^VALKEY_TLS_ENABLED$") and (flagtrue($k; "^PLATFORM_IDENTITY_REDIS_TLS_ENABLED$") or flagtrue($g; "^PLATFORM_GATEWAY_REDIS_TLS_ENABLED$"))) as $ok
  | ([ $rg[] | select(.transit_encryption != true or .mode != "required") | "TransitEncryption=\(.transit_encryption | tostring)/Mode=\(.mode // "미확인")" ]
     + flagbad($c; "^VALKEY_TLS_ENABLED$") + flagbad($k; "^PLATFORM_IDENTITY_REDIS_TLS_ENABLED$") + flagbad($g; "^PLATFORM_GATEWAY_REDIS_TLS_ENABLED$")) as $why
  | row(6; "Valkey TLS: 전송 암호화 required + 앱 TLS 플래그 (VALKEY_TLS / PLATFORM_IDENTITY·GATEWAY_REDIS_TLS)";
      (if denied("^elasticache:DescribeReplicationGroups") then "권한 부족"
       elif ($rg | length) == 0 and ($sl | length) == 0 then (if denied("^elasticache:DescribeServerlessCaches") then "권한 부족" else "누락 (replication group 미발견)" end)
       elif $ok then "확인됨" + (if ($rg | length) == 0 then " (serverless: TLS 전용 설계, 값 미열람)" else "" end)
       elif ($why | length) > 0 then "누락 (\($why | join(", ")))"
       else "누락" end);
      ("ElastiCache: \([ $ec[] | "\(.id) \(.kind) transit=\(.transit_encryption | tostring) mode=\(.mode // "미확인")" ] | join(", ") | orna) · \((vals($c; "^VALKEY_TLS_ENABLED$") + vals($k; "^PLATFORM_IDENTITY_REDIS_TLS_ENABLED$") + vals($g; "^PLATFORM_GATEWAY_REDIS_TLS_ENABLED$")) | join(", ") | orna)"))),
(.rds.clusters // []) as $cl | (.rds.instances // []) as $ins
  | row(7; "RDS force_ssl·CA 식별자";
      (if ($cl | length) == 0 then (if denied("^rds:") then "권한 부족" else "누락 (dev Aurora 클러스터 미발견)" end)
       elif all($cl[]; (.force_ssl == "1" or .force_ssl == "true" or .force_ssl == 1)) then "확인됨" else "누락" end);
      ([ $cl[] as $x | "\($x.id): force_ssl=\($x.force_ssl // "미확인") · CA=\([ $ins[] | select(.cluster == $x.id) | .ca ] | unique | join("/") | orna)" ] | join("; ") | orna)),
row(8; "Core V3 / Carelog V9"; "미확정"; "DB 조회 경로 없음 — 이 진단은 DB에 연결하지 않음"),
"",
"> 판정 규칙: 명시 값(false, 마운트 부재, sslrootcert 불일치, preferred 모드)만 확정 근거. environmentFiles가 있는 서비스의 미설정 항목은 부분 확인.",
"",
"### 권한 부족 (필요 IAM 액션)",
(if (.denied | length) == 0 then "- 없음" else (.denied | map("- 권한 부족: " + .) | join("\n")) end),
"",
"### 기타 오류 (판정 불가 포함)",
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

# task definition 한 건을 마스킹해 ndjson에 붙인다. 파싱 실패는 판정 불가로 기록하고 누락으로 떨어뜨리지 않는다.
emit_td() { # <td-file> <cluster> <service> <ndjson-out>
  local san
  if san=$(jq -c '.taskDefinition // empty' "$1" 2>/dev/null | jq -c "$SANITIZE" 2>/dev/null) && [[ -n $san ]]; then
    jq -nc --arg c "$2" --arg s "$3" --argjson t "$san" '{cluster: $c, service: $s, taskdef: $t}' >>"$4"
  else
    ERRORS+=("$3: task definition 파싱 실패 (판정 불가)")
    jq -nc --arg c "$2" --arg s "$3" '{cluster: $c, service: $s, taskdef: null, parse_failed: true}' >>"$4"
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
    mapfile -t clusters < <(jq -r '.clusterArns[]? | select(test("dev"; "i"))' "$WORK/ecs-clusters.json")
  fi
  : >"$WORK/svc.tsv"
  for arn_c in "${clusters[@]:-}"; do
    [[ -n $arn_c ]] || continue
    cname=${arn_c##*/}
    call "ecs-list-$cname" ecs:ListServices "cluster $cname" aws ecs list-services --cluster "$arn_c" --max-results 100 --output json || continue
    mapfile -t sarns < <(jq -r '.serviceArns[]?' "$WORK/ecs-list-$cname.json")
    for ((i = 0; i < ${#sarns[@]}; i += 10)); do
      call "ecs-desc-$cname-$i" ecs:DescribeServices "cluster $cname" aws ecs describe-services --cluster "$arn_c" --services "${sarns[@]:i:10}" --output json || continue
      jq -r --arg c "$cname" '.services[]? | select(.serviceName | test("gateway|core|carelog|finance"; "i")) | [$c, .serviceName, .taskDefinition] | @tsv' "$WORK/ecs-desc-$cname-$i.json" >>"$WORK/svc.tsv"
    done
  done

  : >"$WORK/services.ndjson"
  while IFS=$'\t' read -r cl sname tdarn; do
    n=$((n + 1))
    if call "td-$n" ecs:DescribeTaskDefinition "$tdarn" aws ecs describe-task-definition --task-definition "$tdarn" --output json; then
      emit_td "$WORK/td-$n.json" "$cl" "$sname" "$WORK/services.ndjson"
    else
      jq -nc --arg c "$cl" --arg s "$sname" '{cluster: $c, service: $s, taskdef: null, fetch_failed: true}' >>"$WORK/services.ndjson"
    fi
  done < "$WORK/svc.tsv"

  # ElastiCache: 전송 암호화 설정만 확인. serverless 캐시는 TLS 전용이 AWS 설계이므로 transit=true로 둔다.
  call ec-rg elasticache:DescribeReplicationGroups 'elasticache(*)' aws elasticache describe-replication-groups --output json || true
  call ec-sc elasticache:DescribeServerlessCaches 'elasticache(*)' aws elasticache describe-serverless-caches --output json || true
  extract '[.ReplicationGroups[]? | select((.ReplicationGroupId // "") | test("dev"; "i")) | {kind: "replication-group", id: .ReplicationGroupId, transit_encryption: .TransitEncryptionEnabled, mode: .TransitEncryptionMode, status: .Status}]' "$WORK/ec-rg.json" "$WORK/ec1.json"
  extract '[.ServerlessCaches[]? | select((.ServerlessCacheName // "") | test("dev"; "i")) | {kind: "serverless", id: .ServerlessCacheName, transit_encryption: true, mode: "serverless-tls", status: .Status}]' "$WORK/ec-sc.json" "$WORK/ec2.json"

  # RDS: 클러스터 목록, 클러스터 파라미터 rds.force_ssl (읽기), 인스턴스 CA
  call rds-clusters rds:DescribeDBClusters 'rds(*)' aws rds describe-db-clusters --output json || true
  call rds-instances rds:DescribeDBInstances 'rds(*)' aws rds describe-db-instances --output json || true
  extract '[.DBClusters[]? | select((.DBClusterIdentifier // "") | test("dev"; "i")) | {id: .DBClusterIdentifier, engine: .Engine, pg: .DBClusterParameterGroup}]' "$WORK/rds-clusters.json" "$WORK/rdsc.json"
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
  local fails=0 fx="$WORK/fixture.json" san="$WORK/san.json" base="$WORK/base.json" rep="$WORK/report.md" all="$WORK/all.out" m="$WORK/m.json" mrep="$WORK/m.md"
  fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

  # 1) 마스킹 필터: 합성 task definition. FAKE-SECRET-* 는 출력에 나오면 안 된다.
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
    {"name":"PLATFORM_GATEWAY_FINANCE_BE_URI","value":"https://user:FAKE-SECRET-URI@finance-be.internal:8080/path"}],
  "secrets":[{"name":"ENROLLMENT_TRUST_KEY","valueFrom":"arn:aws:secretsmanager:ap-northeast-2:124495093425:secret:dev/carelog/enrollment-AbCdEf:key::"}],
  "mountPoints":[{"sourceVolume":"secrets","containerPath":"/run/secrets","readOnly":true}]}],
 "volumes":[{"name":"secrets","host":{"sourcePath":"/x"}}]}}
JSON
  jq '.taskDefinition' "$fx" | jq -c "$SANITIZE" >"$san" || fail 'sanitize 실행'
  grep -q 'finance-be.internal:8080' "$san" || fail 'hostname extraction'
  grep -q '비표준 값 생략' "$san" || fail 'non-standard flag value not masked'
  grep -q 'dev/carelog/enrollment-AbCdEf' "$san" || fail 'secret ref name'
  jq -e '[.containers[0].env[].name] | index("DB_PASSWORD") == null' "$san" >/dev/null || fail 'non-allowlisted env name kept'

  # 2) 항목 3: /run/secrets 경계. 항목 5: sslrootcert 값 검사 (hints는 원문 env 기준, 값 자체는 출력하지 않음).
  local td
  td='{"family":"f","revision":1,"containerDefinitions":[{"name":"c","image":"i","environment":[{"name":"SPRING_DATASOURCE_URL","value":"jdbc:postgresql://db.example:5432/app?sslrootcert=/run/rds-ca.pem"}],"mountPoints":[{"sourceVolume":"v","containerPath":"/run/secretsXYZ"}]}]}'
  jq -c "$SANITIZE" <<<"$td" >"$WORK/s1.json"
  jq -e '.containers[0].hints.secrets_mount == false and .containers[0].hints.sslrootcert_rds_ca == true and .containers[0].hints.rds_ca_mount == false' "$WORK/s1.json" >/dev/null || fail 'secrets mount boundary / sslrootcert=rds-ca hint'
  td='{"family":"f","revision":1,"containerDefinitions":[{"name":"c","image":"i","environment":[{"name":"SPRING_DATASOURCE_URL","value":"jdbc:postgresql://db.example:5432/app?sslrootcert=/tmp/other.pem"},{"name":"PLATFORM_IDENTITY_AUTH_ENABLED","value":"TRUE"},{"name":"PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED","value":"yes"}],"mountPoints":[{"sourceVolume":"v","containerPath":"/run/rds-ca.pem"}]}]}'
  jq -c "$SANITIZE" <<<"$td" >"$WORK/s2.json"
  jq -e '.containers[0].hints.sslrootcert_rds_ca == false and .containers[0].hints.sslrootcert_env == true and .containers[0].hints.rds_ca_mount == true' "$WORK/s2.json" >/dev/null || fail 'sslrootcert other-path hint'
  # 플래그 값: 대소문자 무시 보존("TRUE"), 비표준 값은 마스킹
  jq -e '(.containers[0].env[] | select(.name == "PLATFORM_IDENTITY_AUTH_ENABLED") | .value) == "TRUE" and (.containers[0].env[] | select(.name == "PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED") | .value) == "<비표준 값 생략>"' "$WORK/s2.json" >/dev/null || fail 'flag value preservation / masking'

  # 3) 호스트 추출 (실제 URI 이름 PLATFORM_GATEWAY_FINANCE_BE_URI). 기대값에 SEC가 없으므로 일치 검사가 곧 누출 검사다.
  hostval() { jq -nc --arg v "$1" '{family:"f",revision:1,containerDefinitions:[{name:"c",image:"i",environment:[{name:"PLATFORM_GATEWAY_FINANCE_BE_URI",value:$v}]}]}' | jq -c "$SANITIZE" | jq -r '.containers[0].env[0].value'; }
  expect_host() { local got; got=$(hostval "$1"); [[ $got == "$2" ]] || fail "hostonly: input=[$1] got=[$got] want=[$2]"; }
  expect_host 'https://user:SEC1@SEC2@host.example:8443/x?y=SEC3' 'host.example:8443'
  expect_host 'https://user:SEC1@SEC2@host' 'host'
  expect_host 'https://user:SEC1/SEC2@host.example' 'host.example'
  expect_host 'user:SEC1#SEC2@h' 'h'
  expect_host 'jdbc:sqlserver://db:1433;user=sa;password=SEC1' '<생략>'
  expect_host 'redis://default:SEC1?x=SEC2@h' 'h'
  expect_host 'h.example:443 SEC1' '<생략>'
  expect_host 'https://user:SEC1@' '<생략>'
  expect_host 'jdbc:postgresql://db.internal:5432/carelog?password=SEC1' '<생략>'
  expect_host 'https://db.example:8443/x' 'db.example:8443'

  # 4) 레거시 이름은 실제 바인딩이 아니므로 존재로 치지 않는다 (alias 없음).
  td='{"family":"f","revision":1,"containerDefinitions":[{"name":"gw","image":"i","environment":[{"name":"FINANCE_BE_URI","value":"https://legacy.example:8080"},{"name":"FINANCE_REFERENCE_ENABLED","value":"true"},{"name":"REDIS_TLS_ENABLED","value":"true"}],"secrets":[{"name":"PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET","valueFrom":"arn:aws:secretsmanager:ap-northeast-2:1:secret:dev/gw/trust"}]}]}'
  jq -c "$SANITIZE" <<<"$td" >"$WORK/legacy.json"
  jq -e '[.containers[0].env[].name] | (index("FINANCE_BE_URI") == null and index("FINANCE_REFERENCE_ENABLED") == null and index("REDIS_TLS_ENABLED") == null)' "$WORK/legacy.json" >/dev/null || fail 'legacy names kept in sanitized output'
  jq -c '.containers' "$WORK/legacy.json" >"$WORK/legacy-containers.json"

  # 5) 항목 8: 파싱 실패는 판정 불가로 기록 (누락 아님)
  printf '{not json' >"$WORK/bad.json"
  : >"$WORK/emit.ndjson"
  emit_td "$WORK/bad.json" dev-shared dev-carelog "$WORK/emit.ndjson"
  grep -q '"parse_failed":true' "$WORK/emit.ndjson" || fail 'parse failure not recorded'
  printf '%s\n' "${ERRORS[@]}" | grep -q 'dev-carelog' || fail 'parse failure not in ERRORS (service name)'
  printf '{"taskDefinition":{"family":"f","revision":1,"containerDefinitions":[]}}' >"$WORK/ok.json"
  : >"$WORK/emit2.ndjson"
  emit_td "$WORK/ok.json" dev-shared dev-core "$WORK/emit2.ndjson"
  grep -q '"taskdef":{' "$WORK/emit2.ndjson" && ! grep -q parse_failed "$WORK/emit2.ndjson" || fail 'valid task definition emitted as failure'

  # 6) 판정 규칙: 합성 요약 기준선 (실제 바인딩 이름 사용, 모든 항목 확인됨이어야 함)
  cat >"$base" <<'JSON'
{"services":[
  {"cluster":"dev-shared","service":"dev-carelog","taskdef":{"family":"f","revision":1,"volumes":[],"containers":[
    {"name":"carelog","image":"i","digest":null,"env_files":0,
     "env":[{"name":"VALKEY_TLS_ENABLED","value":"true"},{"name":"CARELOG_IDENTITY_ENROLLMENT_ENABLED","value":"true"},{"name":"CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED","value":"True"}],
     "secrets":[{"name":"CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET","ref":"dev/carelog/enroll"},{"name":"CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET","ref":"dev/carelog/claims"}],
     "mounts":[{"volume":"secrets","path":"/run/secrets","ro":true},{"volume":"rdsca","path":"/run/rds-ca.pem","ro":true}],
     "hints":{"secrets_mount":true,"rds_ca_mount":true,"sslrootcert_env":true,"sslrootcert_rds_ca":true}}]}},
  {"cluster":"dev-shared","service":"dev-core","taskdef":{"containers":[
    {"name":"core","env_files":0,
     "env":[{"name":"SPRING_PROFILES_ACTIVE","value":"dev"},{"name":"PLATFORM_IDENTITY_AUTH_ENABLED","value":"true"},{"name":"PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED","value":"true"},{"name":"PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED","value":"true"},{"name":"PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED","value":"true"},{"name":"PLATFORM_IDENTITY_REDIS_TLS_ENABLED","value":"true"}],
     "secrets":[{"name":"PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL","ref":"x"},{"name":"PLATFORM_IDENTITY_PRODUCT_CLAIMS_SERVICE_SECRET","ref":"y"}],
     "mounts":[],"hints":{}}]}},
  {"cluster":"dev-shared","service":"dev-gateway","taskdef":{"containers":[
    {"name":"gw","env_files":0,
     "env":[{"name":"PLATFORM_GATEWAY_FINANCE_BE_URI","value":"finance-be.internal:8080"},{"name":"PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED","value":"TRUE"},{"name":"PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED","value":"true"},{"name":"PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED","value":"false"},{"name":"PLATFORM_GATEWAY_REDIS_TLS_ENABLED","value":"true"}],
     "secrets":[{"name":"PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET","ref":"z"}],"mounts":[],"hints":{}}]}}
],
"elasticache":[{"kind":"replication-group","id":"dev-shared-valkey","transit_encryption":true,"mode":"required","status":"available"}],
"rds":{"clusters":[{"id":"dev-shared-database","engine":"aurora-postgresql","pg":"pg","force_ssl":"1"}],"instances":[{"cluster":"dev-shared-database","ca":"rds-ca-rsa2048-g1"}]},
"denied":[],"errors":[]}
JSON
  jq -r "$EVAL" "$base" >"$rep" || fail 'render base'
  local r
  for r in 1 2 3 4 5 6 7; do grep -F "| $r |" "$rep" | grep -qF '| 확인됨 |' || fail "base row $r is not 확인됨"; done
  grep -qF '| 1 | carelog /run/secrets 마운트 존재 | 확인됨' "$rep" || fail 'row 1 title/status'

  # 변형 한 건을 렌더링해 지정 행에 기대 문자열이 있는지 확인한다.
  mut() { # <name> <jq-filter> <row> <expected-substring>
    if ! jq "$2" "$base" >"$m" || ! jq -r "$EVAL" "$m" >"$mrep"; then fail "$1: render"; return; fi
    grep -F "| $3 |" "$mrep" | grep -qF -- "$4" || fail "$1: row $3 want [$4]"
  }
  # 실제 이름의 플래그 false -> 누락 + 값=false
  mut core-auth-false '.services[1].taskdef.containers[0].env |= map(if .name == "PLATFORM_IDENTITY_AUTH_ENABLED" then .value = "false" else . end)' 3 '누락 (PLATFORM_IDENTITY_AUTH_ENABLED 값=false)'
  mut core-signup-false '.services[1].taskdef.containers[0].env |= map(if .name == "PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED" then .value = "false" else . end)' 3 '누락 (PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED 값=false)'
  mut core-devdual-false '.services[1].taskdef.containers[0].env |= map(if .name == "PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED" then .value = "false" else . end)' 3 '누락 (PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED 값=false)'
  mut gw-reference-false '.services[2].taskdef.containers[0].env |= map(if .name == "PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED" then .value = "false" else . end)' 4 '누락 (PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED 값=false)'
  mut gw-reference-upper-true '.services[2].taskdef.containers[0].env |= map(if .name == "PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED" then .value = "TRUE" else . end)' 4 '| 확인됨 |'
  # 항목 7: SPRING_PROFILES_ACTIVE 정확 매칭 (devx는 dev 아님, prod,dev는 dev 포함)
  mut profile-devx '.services[1].taskdef.containers[0].env |= map(if .name == "SPRING_PROFILES_ACTIVE" then .value = "devx" else . end)' 3 '누락 (SPRING_PROFILES_ACTIVE 값=devx)'
  mut profile-comma '.services[1].taskdef.containers[0].env |= map(if .name == "SPRING_PROFILES_ACTIVE" then .value = "prod,dev" else . end)' 3 '| 확인됨 |'
  # 항목 5: sslrootcert 값 불일치 / 마운트 부재
  mut rds-ca-mismatch '.services[0].taskdef.containers[0].hints.sslrootcert_rds_ca = false' 2 '누락 (sslrootcert≠/run/rds-ca.pem)'
  mut rds-ca-nomount '.services[0].taskdef.containers[0].hints.rds_ca_mount = false' 2 '누락 (/run/rds-ca.pem 마운트 없음)'
  # 항목 4: 정확한 secret 이름만 인정
  mut secret-exact '.services[0].taskdef.containers[0].secrets |= map(if .name == "CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET" then .name = "CARELOG_INTERNAL_CLAIMS_SECRET" else . end)' 5 '| 누락 |'
  # 항목 12: environmentFiles가 있으면 미설정 항목은 부분 확인
  mut envfiles '.services[0].taskdef.containers[0].env_files = 1 | .services[0].taskdef.containers[0].secrets |= map(select(.name != "CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET"))' 5 '부분 확인(environmentFiles 미열람)'
  # 항목 6: Valkey transit은 required만 인정, preferred는 누락, serverless는 확인됨(주석), RG 권한 거부는 serverless와 무관하게 권한 부족
  mut valkey-preferred '.elasticache[0].mode = "preferred"' 6 'Mode=preferred'
  mut valkey-serverless '.elasticache = [{kind:"serverless", id:"dev-v", transit_encryption:true, mode:"serverless-tls", status:"available"}]' 6 '확인됨 (serverless'
  mut valkey-rg-denied '.denied = ["elasticache:DescribeReplicationGroups on elasticache(*)"] | .elasticache += [{kind:"serverless", id:"dev-v", transit_encryption:true, mode:"serverless-tls", status:"available"}]' 6 '| 권한 부족 |'
  # 항목 8: 파싱/조회 실패는 판정 불가 (누락 아님)
  mut parse-fail '.services[0] = {cluster:"dev-shared", service:"dev-carelog", taskdef:null, parse_failed:true}' 1 '판정 불가(파싱 실패)'
  mut parse-fail-row2 '.services[0] = {cluster:"dev-shared", service:"dev-carelog", taskdef:null, parse_failed:true}' 2 '판정 불가(파싱 실패)'
  mut fetch-fail '.services[0] = {cluster:"dev-shared", service:"dev-carelog", taskdef:null, fetch_failed:true}' 1 '판정 불가(조회 실패)'

  # 레거시 이름 negative: 실제 sanitizer 출력(legacy-containers)을 gateway 자리에 넣으면 누락이어야 하고, 레거시 값은 근거에도 없어야 한다.
  if ! jq --slurpfile lc "$WORK/legacy-containers.json" '.services[2].taskdef.containers = $lc[0]' "$base" >"$m" || ! jq -r "$EVAL" "$m" >"$mrep"; then
    fail 'legacy render'
  else
    grep -F '| 4 |' "$mrep" | grep -qF '| 누락 |' || fail 'legacy name treated as present (row 4 not 누락)'
    grep -qF 'legacy.example' "$mrep" && fail 'legacy value leaked into report'
    grep -qE '(^|[ ,(])FINANCE_REFERENCE_ENABLED=' "$mrep" && fail 'legacy flag shown in report'
  fi

  # 권한 부족 목록 렌더링
  jq '.denied = ["ecs:ListServices on cluster x"]' "$base" >"$m" && jq -r "$EVAL" "$m" >"$mrep"
  grep -qF -- '- 권한 부족: ecs:ListServices on cluster x' "$mrep" || fail 'denied list rendering'

  # 원문 누출 검사: 픽스처의 FAKE 문자열이 마스킹 결과나 리포트에 없어야 한다.
  cat "$san" "$rep" >"$all"
  grep -q 'FAKE' "$all" && fail 'fake secret leaked into output'

  if (( fails )); then
    cat "$rep" >&2
    echo "selftest FAILED ($fails)" >&2
    exit 1
  fi
  cat "$rep"
  echo 'selftest OK: 실제 바인딩 이름 판정, 레거시 이름 비인정, 비밀 미출력, 파싱 실패 처리 확인'
}

case ${1:-} in
  run) run ;;
  selftest) selftest ;;
  *) echo "usage: $0 run|selftest" >&2; exit 2 ;;
esac
