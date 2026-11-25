#!/usr/bin/env bash
# Evidence-pinned, not a standing guard. One run, in order:
#   1. Flyway migration boot of carelog-be (separate step; a precondition, not a DEV-parity claim).
#   2. DEV-parity probe of carelog-be (prod profile, DEV config) on the migrated DB. Remediations (a) /run/secrets,
#      (b) sslmode=disable, (c) VALKEY_TLS_ENABLED=false are applied one at a time, re-probed after each. A failing
#      probe is a finding recorded in the job summary, not a job failure.
#   3. Runtime carelog-be with the cumulative remediations, platform-core, gateway-app and finance-harness-be.
#   4. Verification through the Gateway. Its outcome decides the job.
# Job summary: "## DEV 설정 기동 결과" (probe) and "## 보정 후 E2E 결과" (E2E). Secrets are per-run, masked in logs,
# redacted from summaries and uploaded logs, and never printed.
set -euo pipefail

carelog_source="${1:?carelog-be source checkout is required}"
finance_source="${2:?finance-harness-be source checkout is required}"
platform_source="${3:?platform-services source checkout is required}"
: "${RUNNER_TEMP:?Hosted runner temp directory is required}"
: "${JAVA_HOME_17_X64:?Java 17 is required for carelog-be and Gateway}"
: "${JAVA_HOME_21_X64:?Java 21 is required for platform-core and Finance}"
test "${CARELOG_ENROLLMENT_TARGET:-}" = "real" || {
  echo "CARELOG_ENROLLMENT_TARGET must be 'real' (no stub in this job)." >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verifier="$script_dir/dev-integration-dual-product-e2e.mjs"

carelog_port=18090
carelog_management_port=18093
core_port=18081
core_management_port=19092
gateway_port=18080
gateway_management_port=19091
finance_port=18082
finance_management_port=18083
dead_port=9

log_dir="$RUNNER_TEMP/dev-integration-dual-product-e2e"
artifact_dir="$RUNNER_TEMP/dev-integration-dual-product-e2e-logs"
carelog_access_dir="$log_dir/carelog-access"
carelog_migrate_access_dir="$log_dir/carelog-migrate-access"
carelog_probe_access_dir="$log_dir/carelog-probe-access"
mkdir -m 700 -p "$log_dir" "$artifact_dir" "$carelog_access_dir" "$carelog_migrate_access_dir" "$carelog_probe_access_dir"

# emit: step log plus job summary. note: a bullet in the job summary. Summary text never contains secrets.
emit() {
  printf '%s\n' "$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
}
note() { emit "- $*"; }

export JAVA_HOME="$JAVA_HOME_21_X64"
export PATH="$JAVA_HOME/bin:$PATH"
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
for _ in $(seq 1 60); do
  if pg_isready -q; then break; fi
  sleep 1
done
pg_isready -q

# Per-run secrets. They live only in process environments and are masked before any command can echo them.
identity_db_password="$(openssl rand -hex 32)"
carelog_db_password="$(openssl rand -hex 32)"
finance_db_password="$(openssl rand -hex 32)"
identity_jwt_key="$(openssl rand -hex 64)"
carelog_jwt_key="$(openssl rand -hex 64)"
reference_jwt_key="$(openssl rand -hex 64)"
product_claims_secret="$(openssl rand -hex 32)"
carelog_enrollment_credential="$(openssl rand -hex 32)"
carelog_gateway_internal_secret="$(openssl rand -hex 32)"
gateway_legacy_jwt_key="$(openssl rand -hex 32)"
gateway_internal_secret="$(openssl rand -hex 32)"
finance_trusted_context_proof="$(openssl rand -hex 32)"
all_secrets=(
  "$identity_db_password" "$carelog_db_password" "$finance_db_password" "$identity_jwt_key"
  "$carelog_jwt_key" "$reference_jwt_key" "$product_claims_secret" "$carelog_enrollment_credential"
  "$carelog_gateway_internal_secret" "$gateway_legacy_jwt_key" "$gateway_internal_secret"
  "$finance_trusted_context_proof"
)
for secret in "${all_secrets[@]}"; do
  printf '::add-mask::%s\n' "$secret"
done

# redact: replaces every per-run secret in stdin. Used for summaries, annotations and uploaded logs.
redact() {
  if (( ${#all_secrets[@]} == 0 )); then cat; return 0; fi
  local -a sed_args=()
  local secret
  for secret in "${all_secrets[@]}"; do sed_args+=(-e "s/${secret}/[REDACTED]/g"); done
  sed "${sed_args[@]}"
}

psql -v ON_ERROR_STOP=1 \
  -v identity_password="$identity_db_password" \
  -v carelog_password="$carelog_db_password" \
  -v finance_password="$finance_db_password" <<'SQL'
CREATE ROLE identity_e2e LOGIN PASSWORD :'identity_password';
CREATE ROLE carelog_e2e LOGIN PASSWORD :'carelog_password';
CREATE ROLE finance_e2e LOGIN PASSWORD :'finance_password';
CREATE DATABASE platform_e2e OWNER identity_e2e;
CREATE DATABASE carelog_be_e2e OWNER carelog_e2e;
CREATE DATABASE finance_db OWNER finance_e2e;
SQL
psql -v ON_ERROR_STOP=1 -d platform_e2e -c 'CREATE SCHEMA identity AUTHORIZATION identity_e2e;'

# carelog-be builds on Java 17 (its Gradle toolchain); platform-services and finance-harness-be build on Java 21.
(
  export JAVA_HOME="$JAVA_HOME_17_X64"
  export PATH="$JAVA_HOME/bin:$PATH"
  cd "$carelog_source"
  ./gradlew --no-daemon --console=plain :carelog-be:bootJar
)
export JAVA_HOME="$JAVA_HOME_21_X64"
export PATH="$JAVA_HOME/bin:$PATH"
"$platform_source/gradlew" --no-daemon --console=plain -p "$platform_source" bootJar
(
  cd "$finance_source"
  ./gradlew --no-daemon --console=plain bootJar
)

find_boot_jar() {
  local dir="$1" result
  result="$(find "$dir" -maxdepth 1 -type f -name '*.jar' ! -name '*-plain.jar' -print -quit)"
  [[ -n "$result" && -f "$result" ]]
  printf '%s' "$result"
}
carelog_jar="$(find_boot_jar "$carelog_source/carelog-be/build/libs")"
core_jar="$(find_boot_jar "$platform_source/platform-core/app/build/libs")"
gateway_jar="$(find_boot_jar "$platform_source/gateway-app/build/libs")"
finance_jar="$(find_boot_jar "$finance_source/build/libs")"

# Process-aware readiness: fails fast when the process exits instead of waiting for the full window.
wait_ready() {
  local pid="$1" url="$2" label="$3"
  for _ in $(seq 1 150); do
    if curl --fail --silent --output /dev/null "$url"; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s process exited before readiness.\n' "$label" >&2
      return 1
    fi
    sleep 2
  done
  printf '%s readiness timed out (process still alive).\n' "$label" >&2
  return 1
}

carelog_pid=""
core_pid=""
gateway_pid=""
finance_pid=""
final_level=unset
probe_pass_level=-1
section1_written=0
probe_rows=()
flyway_line="(not run)"

# Remediation state. Levels are cumulative: 0 none; 1 (a) /run/secrets dir; 2 (b) sslmode=disable;
# 3 (c) VALKEY_TLS_ENABLED=false. valkey_tls is derived from the level.
run_secrets_created=0
valkey_tls=true
set_accommodations() {
  local level="$1" sslmode_file="/run/secrets/spring.datasource.hikari.data-source-properties.sslmode"
  if (( level >= 1 )) && [[ ! -d /run/secrets ]]; then
    sudo install -d -m 0755 /run/secrets
    run_secrets_created=1
  fi
  if (( level >= 2 )); then
    printf 'disable' | sudo tee "$sslmode_file" >/dev/null
    sudo chmod 0644 "$sslmode_file"
  else
    sudo rm -f "$sslmode_file"
  fi
  if (( level < 1 && run_secrets_created )); then
    sudo rmdir /run/secrets
    run_secrets_created=0
  fi
  valkey_tls=true
  if (( level >= 3 )); then valkey_tls=false; fi
}

# Carelog env exactly as the DEV task must supply it (values per-run and synthetic). Spring precedence: OS env
# beats application-prod.yml, so CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED=true overrides the literal `false` in
# application-prod.yml (line 39). That override is the DEV-required path under test, not a patch to carelog-be.
carelog_env=(
  SPRING_PROFILES_ACTIVE=prod
  CARELOG_ENVIRONMENT=dev-integration
  SERVER_ADDRESS=127.0.0.1
  SERVER_PORT="$carelog_port"
  CARELOG_MANAGEMENT_PORT="$carelog_management_port"
  SPRING_DATASOURCE_URL='jdbc:postgresql://127.0.0.1:5432/carelog_be_e2e?connectTimeout=3&socketTimeout=10'
  SPRING_DATASOURCE_USERNAME=carelog_e2e
  SPRING_DATASOURCE_PASSWORD="$carelog_db_password"
  CARELOG_CORS_ALLOWED_ORIGINS=http://carelog-dev-integration.invalid
  JWT_SECRET_KEY="$carelog_jwt_key"
  JWT_ACCESS_TOKEN_VALIDITY=900000
  JWT_REFRESH_TOKEN_VALIDITY=3600000
  REDIS_HOST=127.0.0.1
  REDIS_PORT=6379
  GATEWAY_INTERNAL_SECRET="$carelog_gateway_internal_secret"
  CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED=true
  CARELOG_INTERNAL_IDENTITY_CLAIMS_SERVICE_SECRET="$product_claims_secret"
  CARELOG_IDENTITY_ENROLLMENT_ENABLED=true
  CARELOG_IDENTITY_ENROLLMENT_SERVICE_SECRET="$carelog_enrollment_credential"
)

# start_carelog <label> <spring.flyway.enabled> <access dir> <spring.data.redis TLS enabled>
start_carelog() {
  local label="$1" flyway="$2" access_dir="$3" tls="$4"
  nohup env "${carelog_env[@]}" \
    SPRING_FLYWAY_ENABLED="$flyway" \
    VALKEY_TLS_ENABLED="$tls" \
    SERVER_TOMCAT_ACCESSLOG_ENABLED=true \
    SERVER_TOMCAT_ACCESSLOG_BUFFERED=false \
    SERVER_TOMCAT_ACCESSLOG_DIRECTORY="$access_dir" \
    SERVER_TOMCAT_ACCESSLOG_PREFIX=access_log \
    SERVER_TOMCAT_ACCESSLOG_PATTERN='%m %U %s cl=%{Content-Length}i te=%{Transfer-Encoding}i' \
    "$JAVA_HOME_17_X64/bin/java" -jar "$carelog_jar" >"$log_dir/carelog-$label.log" 2>&1 &
  carelog_pid=$!
}
carelog_ready_url="http://127.0.0.1:$carelog_management_port/actuator/health/readiness"

# Log helpers. Each reads a Spring Boot log; none prints secrets.
assert_profile_prod() {
  local log="$1"
  if ! grep -Eq 'The following [0-9]+ profiles? (is|are) active: "?prod"?[[:space:]]*$' "$log"; then
    echo "ASSERT FAILED (L1): active profile is not exactly prod in ${log##*/}." >&2
    return 1
  fi
}
assert_flyway_v9() {
  local log="$1"
  if ! grep -Eq 'now at version v9([^0-9]|$)|Current version of schema .*: 9([^0-9]|$)' "$log"; then
    echo "ASSERT FAILED (L2): Flyway did not report version 9 in ${log##*/}." >&2
    return 1
  fi
}
# extract_cause: first Description line of the Spring failure block, else the deepest "Caused by" line.
extract_cause() {
  local log="$1" cause=""
  if [[ -f "$log" ]] && grep -q 'APPLICATION FAILED TO START' "$log"; then
    cause="$(awk '/^Description:/{d=1; next} d && NF {print; exit}' "$log" || true)"
  fi
  if [[ -z "$cause" && -f "$log" ]]; then
    cause="$(grep -oE 'Caused by: .*' "$log" | tail -n 1 || true)"
  fi
  cause="${cause:-원인 미상 (APPLICATION FAILED TO START 블록 없음)}"
  printf '%s' "$cause" | redact | tr -d '\r' | cut -c1-240
}
# print_failure_block: the Spring Boot Description/Action block (masked) into the step log.
print_failure_block() {
  local log="$1"
  echo "::group::Spring failure block (masked): ${log##*/}"
  if [[ -f "$log" ]] && grep -q 'APPLICATION FAILED TO START' "$log"; then
    awk '/APPLICATION FAILED TO START/{p=1} p{print; if (++n >= 40) exit}' "$log" | redact || true
  else
    grep -E ' (ERROR|WARN) |Caused by: ' "$log" 2>/dev/null | tail -n 20 | redact || true
  fi
  echo '::endgroup::'
}
# annotate_warning: one workflow warning per DEV-parity finding. Escapes the characters annotations cannot carry.
annotate_warning() {
  local message="$1"
  message="${message//%/%25}"
  message="${message//$'\r'/%0D}"
  message="${message//$'\n'/%0A}"
  printf '::warning title=DEV parity::%s\n' "$message"
}
md_cell() { printf '%s' "$1" | sed 's/|/\\|/g'; }

# Summary sections. Each is written once.
write_probe_section() {
  section1_written=1
  emit ''
  emit '## DEV 설정 기동 결과'
  if (( ${#probe_rows[@]} == 0 )); then
    note 'probe 결과: **미실행**. 선행 Flyway 부팅 단계에서 중단됨.'
  elif (( probe_pass_level >= 0 )); then
    note "probe 결과: **PASS**. 보정 ${probe_pass_level}단계에서 readiness UP (prod profile 확인)."
  else
    note 'probe 결과: **FAIL**. 보정 (a)(b)(c)를 누적 적용해도 DEV 설정 기동이 실패함. DEV 정합성 FINDING이며 job 실패 사유가 아님. 최종 판정은 아래 E2E 섹션.'
  fi
  note "선행 Flyway 부팅: ${flyway_line}. 보정 (a)(b)(c)를 모두 적용한 상태에서 수행하고 끝나면 보정을 초기화한 뒤 probe를 시작함. 빈 DB의 스키마 검증이 probe 원인에 섞이지 않도록 하기 위함."
  note 'probe 로그 사본(마스킹)은 artifact `dev-integration-dual-product-e2e-logs`로 업로드 (보존 3일).'
  emit ''
  emit '| 단계 | 이번 단계에서 추가 적용한 보정 | probe 결과 | 원인 (probe 로그, 마스킹) |'
  emit '|---|---|---|---|'
  local row
  for row in "${probe_rows[@]}"; do emit "$row"; done
}
write_e2e_header() {
  emit ''
  emit '## 보정 후 E2E 결과'
  if [[ "$final_level" = unset ]]; then
    note '보정 상태: 선행 단계에서 중단되어 결정되지 않음.'
  else
    note "보정 상태: 누적 ${final_level}단계 (probe 기준 최종 상태, 보정 없는 기준선 probe는 위 표 참고)."
  fi
  emit '### 편차 (DEVIATION)'
  note 'DEVIATION: CI Postgres 18.4 and Valkey 9.1.2 service containers stand in for the DEV RDS and managed Valkey.'
  note 'DEVIATION: all secrets are per-run random values in process environments; DEV resolves them from Secrets Manager/SSM.'
  note 'DEVIATION: CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED=true is an env override of the literal false in application-prod.yml:39. DEV must inject the same env; not verifiable from the repo.'
  note 'DEVIATION: CARELOG_ENVIRONMENT=dev-integration (metrics tag only; DEV value not in repo). Tomcat access log enabled to observe the enrollment PUT.'
  note 'DEVIATION: unused routes (carelog-be direct, RAG, Kakao OAuth) point at a closed port; they are not exercised.'
  note 'DEVIATION (L3): CI Postgres uses POSTGRES_HOST_AUTH_METHOD=trust, so DB password checks are not exercised; DEV uses RDS password auth.'
  note 'DEVIATION (L3): CI Valkey is plaintext with no AUTH; DEV uses managed Valkey with TLS. Redis transport and credentials are not exercised.'
  note 'DEVIATION: migrations run with the single carelog_e2e owner role. DEV migration role is NOT verifiable from this repo.'
  if (( ${final_level/unset/0} >= 1 )); then
    note 'DEVIATION (a): /run/secrets created as an EMPTY directory so the configtree import resolves. DEV supplies no files here.'
  fi
  if (( ${final_level/unset/0} >= 2 )); then
    note 'DEVIATION (b): spring.datasource.hikari.data-source-properties.sslmode=disable (DEV: verify-full with /run/rds-ca.pem). Transport only. verify-full is NOT tested: a self-signed CA and server certificate for the service container were judged too complex for this job.'
  fi
  if (( ${final_level/unset/0} >= 3 )); then
    note 'DEVIATION (c): VALKEY_TLS_ENABLED=false (DEV default true). CI Valkey has no TLS; transport only.'
  fi
}
fail_e2e() {
  local reason="$1"
  if (( section1_written == 0 )); then write_probe_section; fi
  write_e2e_header
  note "**판정: FAIL.** ${reason}"
  exit 1
}

# publish_logs: redacted copies of every run log for the artifact. Runs on every exit path.
publish_logs() {
  local f
  for f in "$log_dir"/*.log "$log_dir/e2e.stderr"; do
    [[ -f "$f" ]] || continue
    redact <"$f" >"$artifact_dir/${f##*/}" 2>/dev/null || true
  done
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  # On failure, surface only ERROR/WARN lines (secrets are redacted before printing).
  if [[ "$status" -ne 0 ]]; then
    local log
    for log in "$log_dir"/*.log; do
      [[ -f "$log" ]] || continue
      echo "--- ${log##*/}: last ERROR/WARN lines"
      grep -E ' (ERROR|WARN) ' "$log" | tail -n 40 | redact || true
    done
    if compgen -G "$carelog_access_dir/access_log*" >/dev/null; then
      echo "--- carelog-be access log: method, path, status, Content-Length, Transfer-Encoding only"
      cat "$carelog_access_dir"/access_log* | awk '{print $1, $2, $3, $4, $5}' | tail -n 60 | redact || true
    fi
  fi
  local pid
  for pid in "$gateway_pid" "$finance_pid" "$core_pid" "$carelog_pid"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
  publish_logs || true
  exit "$status"
}
trap cleanup EXIT INT TERM

# Step 1: Flyway migration boot. It needs (a)(b)(c) to start on CI service containers, so it runs with all three
# applied. This is a precondition for the probe, not a DEV-parity claim. The state is reset before the probe.
set_accommodations 3
start_carelog migrate true "$carelog_migrate_access_dir" "$valkey_tls"
if ! wait_ready "$carelog_pid" "$carelog_ready_url" "carelog-be migration boot"; then
  fail_e2e 'Flyway 선행 부팅이 readiness에 도달하지 못함 (마스킹된 migrate 로그 artifact 참고).'
fi
assert_profile_prod "$log_dir/carelog-migrate.log" || fail_e2e 'L1 assertion failed: migration boot active profile is not prod.'
kill "$carelog_pid" 2>/dev/null || true
wait "$carelog_pid" 2>/dev/null || true
assert_flyway_v9 "$log_dir/carelog-migrate.log" || fail_e2e 'L2 assertion failed: Flyway did not reach v9.'
flyway_line="$(grep -m1 -E 'Successfully applied|Schema .* is up to date' "$log_dir/carelog-migrate.log" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ +//' || true)"
flyway_line="${flyway_line:-Flyway summary line not found}, V9 확인됨"
set_accommodations 0

# Step 2: DEV-parity probe on the migrated DB. Starts from the bare DEV config. Each level adds one remediation
# and re-probes. Stops at the first level that boots (cumulative remediations needed).
probe_labels=(
  '없음 (기준선: DEV 설정 그대로)'
  '(a) /run/secrets configtree 디렉터리 생성 (빈 디렉터리)'
  '(b) DB sslmode=disable (DEV: verify-full + /run/rds-ca.pem; CI Postgres는 평문)'
  '(c) VALKEY_TLS_ENABLED=false (DEV 기본 true; CI Valkey는 평문)'
)
for level in 0 1 2 3; do
  set_accommodations "$level"
  probe_log="$log_dir/carelog-probe-L$level.log"
  start_carelog "probe-L$level" false "$carelog_probe_access_dir" "$valkey_tls"
  probe_pid="$carelog_pid"
  probe_result=FAIL
  if wait_ready "$probe_pid" "$carelog_ready_url" "carelog-be DEV probe L$level"; then probe_result=PASS; fi
  kill "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true

  if [[ "$probe_result" = PASS ]]; then
    if ! assert_profile_prod "$probe_log"; then
      fail_e2e 'L1 assertion failed: DEV-parity probe active profile is not prod.'
    fi
    probe_rows+=("| $level | ${probe_labels[$level]} | PASS | — |")
    probe_pass_level=$level
    break
  fi
  cause="$(extract_cause "$probe_log")"
  probe_rows+=("| $level | ${probe_labels[$level]} | FAIL | $(md_cell "$cause") |")
  annotate_warning "[L$level] ${probe_labels[$level]}: $cause"
  print_failure_block "$probe_log"
done

if (( probe_pass_level >= 0 )); then final_level=$probe_pass_level; else final_level=3; fi
set_accommodations "$final_level"
write_probe_section

# Step 3: runtime carelog-be with the cumulative remediations, Flyway explicitly off (DEV gate).
start_carelog runtime false "$carelog_access_dir" "$valkey_tls"
if ! wait_ready "$carelog_pid" "$carelog_ready_url" "carelog-be runtime"; then
  fail_e2e "carelog-be 런타임이 readiness에 도달하지 못함 (보정 ${final_level}단계). 누적 보정으로도 기동 실패."
fi
assert_profile_prod "$log_dir/carelog-runtime.log" || fail_e2e 'L1 assertion failed: runtime active profile is not prod.'

# platform-core: Carelog auth and Finance reference together. DEV dual-auth opt-in (dev profile required).
nohup env \
  SPRING_PROFILES_ACTIVE=finance-reference,dev \
  PLATFORM_ENVIRONMENT=dev-integration-dual-product-e2e \
  PLATFORM_CORE_PORT="$core_port" \
  PLATFORM_CORE_MANAGEMENT_PORT="$core_management_port" \
  SERVER_ADDRESS=127.0.0.1 \
  MANAGEMENT_SERVER_ADDRESS=127.0.0.1 \
  PLATFORM_IDENTITY_AUTH_ENABLED=true \
  PLATFORM_IDENTITY_PERSISTENCE_ENABLED=true \
  PLATFORM_IDENTITY_DATASOURCE_URL='jdbc:postgresql://127.0.0.1:5432/platform_e2e?currentSchema=identity&connectTimeout=3&socketTimeout=10' \
  PLATFORM_IDENTITY_DATASOURCE_USERNAME=identity_e2e \
  PLATFORM_IDENTITY_DATASOURCE_PASSWORD="$identity_db_password" \
  PLATFORM_IDENTITY_FLYWAY_DATASOURCE_URL='jdbc:postgresql://127.0.0.1:5432/platform_e2e?currentSchema=identity&connectTimeout=3&socketTimeout=10' \
  PLATFORM_IDENTITY_FLYWAY_DATASOURCE_USERNAME=identity_e2e \
  PLATFORM_IDENTITY_FLYWAY_DATASOURCE_PASSWORD="$identity_db_password" \
  PLATFORM_IDENTITY_REDIS_HOST=127.0.0.1 \
  PLATFORM_IDENTITY_REDIS_PORT=6379 \
  PLATFORM_IDENTITY_REDIS_KEY_PREFIX=dev-integration-dual-e2e:identity: \
  PLATFORM_IDENTITY_JWT_SECRET_KEY="$identity_jwt_key" \
  PLATFORM_IDENTITY_JWT_ACCESS_TOKEN_VALIDITY=900000 \
  PLATFORM_IDENTITY_JWT_REFRESH_TOKEN_VALIDITY=3600000 \
  PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED=true \
  PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL="http://127.0.0.1:$carelog_port" \
  PLATFORM_IDENTITY_PRODUCT_CLAIMS_SERVICE_SECRET="$product_claims_secret" \
  PLATFORM_IDENTITY_KAKAO_CLIENT_ID=dev-integration-dual-unused \
  PLATFORM_IDENTITY_KAKAO_CLIENT_SECRET=dev-integration-dual-unused-secret \
  PLATFORM_IDENTITY_KAKAO_AUTHORIZATION_URI="http://127.0.0.1:$dead_port/oauth/authorize" \
  PLATFORM_IDENTITY_KAKAO_TOKEN_URI="http://127.0.0.1:$dead_port/oauth/token" \
  PLATFORM_IDENTITY_KAKAO_USER_INFO_URI="http://127.0.0.1:$dead_port/v2/user/me" \
  PLATFORM_IDENTITY_OAUTH_KAKAO_WEB_REDIRECT_URI="http://dev-integration-dual.invalid/oauth/kakao/callback" \
  PLATFORM_IDENTITY_OAUTH_KAKAO_MOBILE_REDIRECT_URI="http://dev-integration-dual.invalid/oauth/kakao/callback" \
  PLATFORM_IDENTITY_OAUTH_ALLOWED_RETURN_ORIGINS="http://dev-integration-dual.invalid" \
  PLATFORM_IDENTITY_CARELOG_REGISTRATION_ENABLED=true \
  PLATFORM_IDENTITY_CARELOG_ENROLLMENT_ENABLED=true \
  PLATFORM_IDENTITY_CARELOG_ENROLLMENT_BASE_URL="http://127.0.0.1:$carelog_port" \
  PLATFORM_IDENTITY_CARELOG_ENROLLMENT_CREDENTIAL="$carelog_enrollment_credential" \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_ENABLED=true \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_SIGNUP_ENABLED=true \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_DEV_DUAL_AUTH_ENABLED=true \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_SIGNING_KEY="$reference_jwt_key" \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_ISSUER=urn:ranikunlabs:identity:finance:reference \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_AUDIENCE=finance-journal-reference \
  PLATFORM_IDENTITY_FINANCE_REFERENCE_JWT_ACCESS_TOKEN_TTL_SECONDS=300 \
  "$JAVA_HOME_21_X64/bin/java" -jar "$core_jar" >"$log_dir/core.log" 2>&1 &
core_pid=$!
wait_ready "$core_pid" "http://127.0.0.1:$core_management_port/actuator/health/readiness" Core \
  || fail_e2e 'platform-core가 readiness에 도달하지 못함.'

# gateway-app: Carelog registration and Finance reference routes. Finance is reached via the yml route
# (Path=/api/finance/**, StripPrefix=1) that PLATFORM_GATEWAY_FINANCE_BE_URI points at.
nohup env \
  SPRING_PROFILES_ACTIVE=finance-trusted-context-reference \
  PLATFORM_ENVIRONMENT=dev-integration-dual-product-e2e \
  PLATFORM_GATEWAY_PORT="$gateway_port" \
  SERVER_ADDRESS=127.0.0.1 \
  MANAGEMENT_SERVER_ADDRESS=127.0.0.1 \
  PLATFORM_GATEWAY_MANAGEMENT_PORT="$gateway_management_port" \
  PLATFORM_GATEWAY_REDIS_HOST=127.0.0.1 \
  PLATFORM_GATEWAY_REDIS_PORT=6379 \
  PLATFORM_GATEWAY_REDIS_KEY_PREFIX=dev-integration-dual-e2e:gateway: \
  SPRING_DATA_REDIS_TIMEOUT=2s \
  PLATFORM_GATEWAY_AUTH_URI="http://127.0.0.1:$core_port" \
  PLATFORM_GATEWAY_FINANCE_BE_URI="http://127.0.0.1:$finance_port" \
  PLATFORM_GATEWAY_CARELOG_BE_URI="http://127.0.0.1:$dead_port" \
  PLATFORM_GATEWAY_CARELOG_RAG_URI="http://127.0.0.1:$dead_port" \
  PLATFORM_GATEWAY_CARELOG_REGISTRATION_ENABLED=true \
  PLATFORM_GATEWAY_JWT_VERIFICATION_SECRET="$gateway_legacy_jwt_key" \
  PLATFORM_GATEWAY_INTERNAL_SECRET="$gateway_internal_secret" \
  PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_ENABLED=false \
  PLATFORM_GATEWAY_FINANCE_TRUSTED_CONTEXT_SERVICE_SECRET="$finance_trusted_context_proof" \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_ENABLED=true \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_JWT_VERIFICATION_KEY="$reference_jwt_key" \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_ISSUER=urn:ranikunlabs:identity:finance:reference \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_AUDIENCE=finance-journal-reference \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_PURPOSE=access \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_CLOCK_SKEW_SECONDS=30 \
  PLATFORM_GATEWAY_FINANCE_REFERENCE_MAX_TOKEN_LIFETIME_SECONDS=300 \
  "$JAVA_HOME_17_X64/bin/java" -jar "$gateway_jar" >"$log_dir/gateway.log" 2>&1 &
gateway_pid=$!

# finance-harness-be: trusted-context reference profile, as in the Finance dual-auth job.
nohup env \
  SPRING_PROFILES_ACTIVE=finance-trusted-context-reference \
  FINANCE_METRICS_ENVIRONMENT=dev-integration-dual-product-e2e \
  SERVER_PORT="$finance_port" \
  FINANCE_MANAGEMENT_PORT="$finance_management_port" \
  SERVER_ADDRESS=127.0.0.1 \
  MANAGEMENT_SERVER_ADDRESS=127.0.0.1 \
  FINANCE_HTTP_BIND_ADDRESS=127.0.0.1 \
  FINANCE_MANAGEMENT_BIND_ADDRESS=127.0.0.1 \
  FINANCE_DB_URL='jdbc:postgresql://127.0.0.1:5432/finance_db?connectTimeout=3&socketTimeout=10' \
  FINANCE_DB_USERNAME=finance_e2e \
  FINANCE_DB_PASSWORD="$finance_db_password" \
  FINANCE_DB_APPLICATION_NAME=dev-integration-dual-product-e2e \
  FINANCE_AUTH_MODE=trusted-context \
  FINANCE_AUTH_TRUSTED_CONTEXT_SERVICE_SECRET="$finance_trusted_context_proof" \
  "$JAVA_HOME_21_X64/bin/java" -jar "$finance_jar" >"$log_dir/finance.log" 2>&1 &
finance_pid=$!

wait_ready "$finance_pid" "http://127.0.0.1:$finance_management_port/actuator/health/readiness" Finance \
  || fail_e2e 'finance-harness-be가 readiness에 도달하지 못함.'
wait_ready "$gateway_pid" "http://127.0.0.1:$gateway_management_port/actuator/health/readiness" Gateway \
  || fail_e2e 'gateway-app이 readiness에 도달하지 못함.'

# Step 4: verification through the Gateway. Its stdout is the verified-assertion block; stderr carries the stage.
write_e2e_header
e2e_rc=0
E2E_GATEWAY_URL="http://127.0.0.1:$gateway_port" \
E2E_CARELOG_URL="http://127.0.0.1:$carelog_port" \
E2E_CARELOG_ACCESS_LOG_DIR="$carelog_access_dir" \
node "$verifier" 2>"$log_dir/e2e.stderr" || e2e_rc=$?
cat "$log_dir/e2e.stderr" >&2 || true
if (( e2e_rc == 0 )); then
  note '**판정: PASS.**'
else
  stage_line="$(redact <"$log_dir/e2e.stderr" | tail -n 1 || true)"
  note "**판정: FAIL.** ${stage_line:-stage unknown}"
fi
exit "$e2e_rc"
