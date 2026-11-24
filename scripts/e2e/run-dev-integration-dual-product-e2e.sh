#!/usr/bin/env bash
# Evidence-pinned, not a standing guard. One run boots, in order: DEV-parity carelog-be (prod profile) with a
# separate Flyway boot, platform-core (Carelog auth + Finance reference, DEV dual-auth), gateway-app and
# finance-harness-be, then verifies through the Gateway. Every deviation from DEV and every DEV-parity finding is
# recorded in the job summary. Secrets are per-run, masked, and never printed.
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
carelog_access_dir="$log_dir/carelog-access"
carelog_migrate_access_dir="$log_dir/carelog-migrate-access"
carelog_probe_access_dir="$log_dir/carelog-probe-access"
mkdir -m 700 -p "$log_dir" "$carelog_access_dir" "$carelog_migrate_access_dir" "$carelog_probe_access_dir"

# Summary lines are printed and appended to the job summary. They never contain secrets or payloads.
note() {
  printf '%s\n' "$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf -- '- %s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi
}

note '### Deviations from DEV (always in effect)'
note 'DEVIATION: CI Postgres 18.4 and Valkey 9.1.2 service containers stand in for the DEV RDS and managed Valkey.'
note 'DEVIATION: all secrets are per-run random values in process environments; DEV resolves them from Secrets Manager/SSM.'
note 'DEVIATION: CARELOG_INTERNAL_IDENTITY_CLAIMS_ENABLED=true is an env override of the literal false in application-prod.yml:39. DEV must inject the same env; not verifiable from the repo.'
note 'DEVIATION: CARELOG_ENVIRONMENT=dev-integration (metrics tag only; DEV value not in repo). Tomcat access log enabled to observe the enrollment PUT.'
note 'DEVIATION: unused routes (carelog-be direct, RAG, Kakao OAuth) point at a closed port; they are not exercised.'

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
for secret in "$identity_db_password" "$carelog_db_password" "$finance_db_password" "$identity_jwt_key" \
  "$carelog_jwt_key" "$reference_jwt_key" "$product_claims_secret" "$carelog_enrollment_credential" \
  "$carelog_gateway_internal_secret" "$gateway_legacy_jwt_key" "$gateway_internal_secret" \
  "$finance_trusted_context_proof"; do
  printf '::add-mask::%s\n' "$secret"
done

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
  printf '%s readiness failed; process logs remain on the ephemeral runner only.\n' "$label" >&2
  return 1
}

carelog_pid=""
core_pid=""
gateway_pid=""
finance_pid=""
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  # On failure, surface only ERROR/WARN lines (secrets are already ::add-mask::ed).
  if [[ "$status" -ne 0 ]]; then
    for log in "$log_dir/carelog-probe.log" "$log_dir/carelog-migrate.log" "$log_dir/carelog-runtime.log" \
      "$log_dir/core.log" "$log_dir/gateway.log" "$log_dir/finance.log"; do
      if [[ -f "$log" ]]; then
        echo "--- ${log##*/}: last ERROR/WARN lines"
        grep -E ' (ERROR|WARN) ' "$log" | tail -n 40 || true
      fi
    done
    if compgen -G "$carelog_access_dir/access_log*" >/dev/null; then
      echo "--- carelog-be access log: method, path, status, Content-Length, Transfer-Encoding only"
      cat "$carelog_access_dir"/access_log* | awk '{print $1, $2, $3, $4, $5}' | tail -n 60 || true
    fi
  fi
  for pid in "$gateway_pid" "$finance_pid" "$core_pid" "$carelog_pid"; do
    if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  done
  wait 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT INT TERM

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
  local label="$1" flyway="$2" access_dir="$3" valkey_tls="$4"
  nohup env "${carelog_env[@]}" \
    SPRING_FLYWAY_ENABLED="$flyway" \
    VALKEY_TLS_ENABLED="$valkey_tls" \
    SERVER_TOMCAT_ACCESSLOG_ENABLED=true \
    SERVER_TOMCAT_ACCESSLOG_BUFFERED=false \
    SERVER_TOMCAT_ACCESSLOG_DIRECTORY="$access_dir" \
    SERVER_TOMCAT_ACCESSLOG_PREFIX=access_log \
    SERVER_TOMCAT_ACCESSLOG_PATTERN='%m %U %s cl=%{Content-Length}i te=%{Transfer-Encoding}i' \
    "$JAVA_HOME_17_X64/bin/java" -jar "$carelog_jar" >"$log_dir/carelog-$label.log" 2>&1 &
  carelog_pid=$!
}
carelog_ready_url="http://127.0.0.1:$carelog_management_port/actuator/health/readiness"

# Step 1: DEV-parity probe. Exactly the DEV-equivalent config: prod profile, configtree import of /run/secrets
# (non-optional), verify-full DB TLS, Valkey TLS on, Flyway off. Expected to fail if DEV-equivalent runtime lacks
# the /run/secrets directory or the RDS CA file, which the ECS module and carelog image do not provide.
start_carelog probe false "$carelog_probe_access_dir" true
probe_pid="$carelog_pid"
probe_status=pass
if ! wait_ready "$probe_pid" "$carelog_ready_url" "carelog-be DEV-parity probe"; then
  probe_status=fail
  kill "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true
  failure_classes="$(grep -oE '[A-Za-z0-9_.]+(Exception|Error)' "$log_dir/carelog-probe.log" | sort | uniq -c | sort -rn | head -n 5 | awk '{print $2}' | paste -sd ' ' - || true)"
  note "FINDING (DEV parity): carelog-be prod profile did not start with the DEV-equivalent config. Exception classes: ${failure_classes:-unknown}."
  if [[ ! -d /run/secrets ]]; then
    note "FINDING (DEV parity): /run/secrets does not exist on the runtime. application-prod.yml:3 imports configtree:/run/secrets/ (not optional); ecs-service module declares no volumes and the carelog Dockerfile creates no such directory."
    sudo install -d -m 0755 /run/secrets
    note "DEVIATION: /run/secrets created as an EMPTY directory so the configtree import resolves. DEV supplies no files here (secrets arrive as ECS env)."
  fi
  # DB TLS deviation: verify-full needs /run/rds-ca.pem and a TLS Postgres. CI Postgres is plaintext, so only
  # sslmode is overridden (through configtree, which outranks the application-prod.yml value).
  printf 'disable' | sudo tee /run/secrets/spring.datasource.hikari.data-source-properties.sslmode >/dev/null
  sudo chmod 0644 /run/secrets/spring.datasource.hikari.data-source-properties.sslmode
  note "DEVIATION: spring.datasource.hikari.data-source-properties.sslmode=disable (DEV: verify-full with /run/rds-ca.pem). Transport only; the CI Postgres has no TLS."
  note "DEVIATION: VALKEY_TLS_ENABLED=false (DEV default true). CI Valkey has no TLS; transport only."
  valkey_tls=false
else
  kill "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true
  note "DEV-parity probe: carelog-be started with the DEV-equivalent config. No overrides needed."
  valkey_tls=true
fi

# Step 2: Flyway as a separate boot (prod disables it at runtime; DEV runs migrations in a separate role/step).
start_carelog migrate true "$carelog_migrate_access_dir" "$valkey_tls"
wait_ready "$carelog_pid" "$carelog_ready_url" "carelog-be migration boot" || exit 1
kill "$carelog_pid" 2>/dev/null || true
wait "$carelog_pid" 2>/dev/null || true
flyway_line="$(grep -m1 -E 'Successfully applied|Schema .* is up to date' "$log_dir/carelog-migrate.log" | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ +//' || true)"
note "Flyway boot (SPRING_FLYWAY_ENABLED=true, then stopped): ${flyway_line:-no Flyway summary line found}."
note "DEVIATION: migrations run with the single carelog_e2e owner role. DEV migration role is NOT verifiable from this repo."

# Step 3: runtime carelog-be exactly as the DEV gate requires (SPRING_FLYWAY_ENABLED=false explicitly).
start_carelog runtime false "$carelog_access_dir" "$valkey_tls"
wait_ready "$carelog_pid" "$carelog_ready_url" "carelog-be runtime" || exit 1
note "carelog-be runtime: prod profile readiness UP (SPRING_FLYWAY_ENABLED=false, dev-integration environment tag)."

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
wait_ready "$core_pid" "http://127.0.0.1:$core_management_port/actuator/health/readiness" Core

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

wait_ready "$finance_pid" "http://127.0.0.1:$finance_management_port/actuator/health/readiness" Finance
wait_ready "$gateway_pid" "http://127.0.0.1:$gateway_management_port/actuator/health/readiness" Gateway

E2E_GATEWAY_URL="http://127.0.0.1:$gateway_port" \
E2E_CARELOG_URL="http://127.0.0.1:$carelog_port" \
E2E_CARELOG_ACCESS_LOG_DIR="$carelog_access_dir" \
node "$verifier"
