#!/usr/bin/env bash
# Core rollback proof (isolated). Runs PostgreSQL, Redis and Core containers on a private Docker network.
#
# Question: after the NEW Core image applied Flyway V3, can the PREVIOUS Core image start on that database?
#
# Requirements: Docker (Linux engine or Docker Desktop), bash, openssl-free (uses /dev/urandom), optional
# aws CLI with read access to ECR when the two Core images are not present locally (see README.md).
# Usage:   bash candidates/core-rollback-test/run.sh
# Exit:    0 only when no step FAILs (SKIP is reported and is not a failure).
#
# Everything secret is generated here at runtime (throwaway), written to a mktemp directory with mode 600,
# and removed on exit together with every container, network and temporary Docker config this script made.
set -u
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: keep docker -v paths unchanged

HERE=$(cd "$(dirname "$0")" && pwd)
ECR=124495093425.dkr.ecr.ap-northeast-2.amazonaws.com
PREV_REF=${CORE_PREVIOUS_IMAGE:-$ECR/ranikun/platform/core@sha256:ad9f84289f980aa708ec15213050fb912168c6f76d3c61c93d67ecdc27780001}
NEW_REF=${CORE_NEW_IMAGE:-$ECR/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf}
PG_IMAGE=${POSTGRES_IMAGE:-postgres:16-alpine}
REDIS_IMAGE=${REDIS_IMAGE:-redis:7-alpine}
JDK_IMAGE=${JDK_IMAGE:-eclipse-temurin:21-jdk}
HELPER_IMAGE=${HELPER_IMAGE:-busybox:latest}
AWS_REGION=${AWS_REGION:-ap-northeast-2}

RUN="crt$(date +%s)$$"
LABEL="core-rollback-test=$RUN"
NET="core-rb-$RUN"
PG="crt-pg-$RUN"
REDIS="crt-redis-$RUN"
CORE_PREV="crt-core-prev-$RUN"
CORE_NEW="crt-core-new-$RUN"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/core-rb.XXXXXX")
chmod 700 "$WORK"
FAILS=0
ECR_CFG=""

cleanup() {
  ids=$(docker ps -aq --filter "label=$LABEL" 2>/dev/null)
  [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  [ -n "$ECR_CFG" ] && rm -rf "$ECR_CFG"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

result() { # <id> <PASS|FAIL|SKIP> <text>
  printf '[%s] %s  %s\n' "$2" "$1" "$3"
  [ "$2" = FAIL ] && FAILS=$((FAILS + 1))
  return 0
}
note() { printf '      %s\n' "$*"; }
rand() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
# Host path as seen by the Docker CLI (Git Bash needs cygpath -m; Linux passes through unchanged).
dpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# ---------- images ----------
ensure_image() { # <ref>: use local image; else pull read-only (ECR via temporary docker config)
  local ref=$1
  docker image inspect "$ref" >/dev/null 2>&1 && return 0
  case "$ref" in
    "$ECR"/*)
      ECR_CFG=$(mktemp -d "${TMPDIR:-/tmp}/core-rb-docker.XXXXXX")
      aws ecr get-login-password --region "$AWS_REGION" \
        | DOCKER_CONFIG="$ECR_CFG" docker login --username AWS --password-stdin "$ECR" >/dev/null 2>&1 || return 1
      DOCKER_CONFIG="$ECR_CFG" docker pull "$ref" >/dev/null 2>&1 || return 1
      DOCKER_CONFIG="$ECR_CFG" docker logout "$ECR" >/dev/null 2>&1
      rm -rf "$ECR_CFG"; ECR_CFG=""
      ;;
    *) docker pull "$ref" >/dev/null 2>&1 || return 1 ;;
  esac
}

# ---------- helpers ----------
helper() { docker run --rm --network "$NET" --label "$LABEL" "$HELPER_IMAGE" "$@"; }
curl_run() { docker run --rm --network "$NET" --label "$LABEL" --entrypoint curl "$JDK_IMAGE" -sS "$@"; }
pgsql() { # <role> <sql-file> [psql -v args...]: runs through the local socket inside the PostgreSQL container
  local role=$1 file=$2; shift 2
  docker exec -i "$PG" psql -U "$role" -d app -X -A -t -v ON_ERROR_STOP=1 "$@" < "$file"
}
pgq() { # <role> <sql text>: single query, unaligned, tuples only
  local role=$1 sql=$2
  printf '%s\n' "$sql" > "$WORK/q.sql"
  pgsql "$role" "$WORK/q.sql"
}
redact() { sed -E 's/(password|PASSWORD|secret|SECRET|token|TOKEN)[=:][^ ,"]*/\1=<redacted>/g'; }
core_env_file() { # <file> <mode:migrator|runtime> [extra KEY=VALUE ...]
  local f=$1 mode=$2; shift 2
  {
    echo "PLATFORM_CORE_PORT=8080"
    echo "PLATFORM_CORE_MANAGEMENT_PORT=9092"
    echo "PLATFORM_ENVIRONMENT=local"
    echo "PLATFORM_IDENTITY_AUTH_ENABLED=true"
    echo "PLATFORM_IDENTITY_DATASOURCE_URL=jdbc:postgresql://$PG:5432/app?sslmode=disable"
    echo "PLATFORM_IDENTITY_DATASOURCE_USERNAME=identity_runtime"
    echo "PLATFORM_IDENTITY_DATASOURCE_PASSWORD=$RUNTIME_PW"
    echo "PLATFORM_IDENTITY_REDIS_HOST=$REDIS"
    echo "PLATFORM_IDENTITY_REDIS_PORT=6379"
    echo "PLATFORM_IDENTITY_REDIS_KEY_PREFIX=core-rb"
    echo "PLATFORM_IDENTITY_REDIS_TLS_ENABLED=false"
    echo "PLATFORM_IDENTITY_JWT_SECRET_KEY=$JWT_KEY"
    echo "PLATFORM_IDENTITY_JWT_ACCESS_TOKEN_VALIDITY=900000"
    echo "PLATFORM_IDENTITY_JWT_REFRESH_TOKEN_VALIDITY=604800000"
    echo "PLATFORM_IDENTITY_PRODUCT_CLAIMS_ENABLED=true"
    echo "PLATFORM_IDENTITY_PRODUCT_CLAIMS_BASE_URL=http://$CLAIMS:8080"
    echo "PLATFORM_IDENTITY_PRODUCT_CLAIMS_SERVICE_SECRET=$CLAIMS_SECRET"
    if [ "$mode" = migrator ]; then
      echo "PLATFORM_IDENTITY_FLYWAY_DATASOURCE_URL=jdbc:postgresql://$PG:5432/app?sslmode=disable"
      echo "PLATFORM_IDENTITY_FLYWAY_DATASOURCE_USERNAME=identity_owner"
      echo "PLATFORM_IDENTITY_FLYWAY_DATASOURCE_PASSWORD=$OWNER_PW"
    fi
    for kv in "$@"; do echo "$kv"; done
  } > "$f"
  chmod 600 "$f"
}
start_core() { # <name> <image> <mode> [KEY=VALUE ...]
  local name=$1 image=$2 mode=$3; shift 3
  local envf="$WORK/$name.env"
  core_env_file "$envf" "$mode" "$@"
  rm_core "$name"
  docker run -d --name "$name" --network "$NET" --label "$LABEL" --env-file "$(dpath "$envf")" "$image" >/dev/null
}
wait_core() { # <name>: 0 = management health UP, 1 = container exited, 2 = timeout
  local name=$1 i state
  for i in $(seq 1 150); do
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
    [ "$state" = running ] || return 1
    if helper wget -q -O - "http://$name:9092/actuator/health" 2>/dev/null | grep -q '"UP"'; then
      # management UP is not enough: wait until the API port answers (not 503 while the servlet context starts)
      api=$(curl_run -s -o /dev/null -w '%{http_code}' "http://$name:8080/api/v1/auth/login" 2>/dev/null)
      [ -n "$api" ] && [ "$api" != 503 ] && return 0
    fi
    sleep 2
  done
  return 2
}
core_log_cause() { # <name> <regex>: first matching lines, secrets redacted
  docker logs "$1" 2>&1 | grep -E "$2" | head -n 4 | redact | cut -c1-260
}
# Keep the full container log (secrets redacted) before a container is removed; copied to CRT_LOG_DIR if set.
LOGDIR="$WORK/logs"; mkdir -p "$LOGDIR"
LOGSEQ=0
save_logs() { # <name>: one file per container start (sequence number keeps repeated names apart)
  docker inspect "$1" >/dev/null 2>&1 || return 0
  LOGSEQ=$((LOGSEQ + 1)); local f="$LOGDIR/$(printf '%02d' $LOGSEQ)-$1.log"
  docker logs "$1" 2>&1 | redact > "$f" 2>/dev/null
  if [ -n "${CRT_LOG_DIR:-}" ]; then mkdir -p "$CRT_LOG_DIR" && cp "$f" "$CRT_LOG_DIR/"; fi
}
rm_core() { # <name>: save logs, then remove
  save_logs "$1"; docker rm -f "$1" >/dev/null 2>&1
}
# Deepest cause: the last 'Caused by' line and the last bean-creation line in the saved log.
root_cause() { # <name>: works while the container exists; falls back to the saved log
  { docker logs "$1" 2>&1 || cat "$(ls -1 "$LOGDIR"/*-"$1".log 2>/dev/null | tail -n 1)" 2>/dev/null; } | grep -E 'Caused by:' | tail -n 2 | redact | cut -c1-300
}
# HTTP via curl (JDK image): body, then an explicit "HTTP <code>" line that status_of reads.
http() { # <GET|POST> <name> <path> [json-body]
  local m=$1 n=$2 p=$3 b=${4-}
  if [ "$m" = GET ]; then curl_run -X GET -o /dev/stdout -w '\nHTTP %{http_code}\n' "http://$n:8080$p" 2>&1
  else curl_run -X POST -H 'Content-Type: application/json' --data "$b" -o /dev/stdout -w '\nHTTP %{http_code}\n' "http://$n:8080$p" 2>&1
  fi
}
status_of() { printf '%s\n' "$1" | sed -n 's/^HTTP \([0-9][0-9][0-9]\)$/\1/p' | tail -n 1; }
json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -n 1; }

# ---------- 0. preflight ----------
echo "== Core rollback proof  run=$RUN"
echo "   previous: $PREV_REF"
echo "   new:      $NEW_REF"
echo "   postgres: $PG_IMAGE   redis: $REDIS_IMAGE   jdk: $JDK_IMAGE"
for ref in "$PREV_REF" "$NEW_REF"; do
  if ensure_image "$ref"; then result "preflight:image" PASS "image present: ${ref##*@}"
  else result "preflight:image" FAIL "image not available locally or pullable: ${ref##*@}"; exit 1; fi
done
for ref in "$PG_IMAGE" "$REDIS_IMAGE" "$JDK_IMAGE" "$HELPER_IMAGE"; do
  ensure_image "$ref" || { result "preflight:image" FAIL "helper image missing: $ref"; exit 1; }
done
docker network create --label "$LABEL" "$NET" >/dev/null || { result "preflight:net" FAIL "network create failed"; exit 1; }

# Claims stub: Core calls the product-claims endpoint on every login, refresh and rotation (AuthServiceImpl).
CLAIMS="crt-claims-$RUN"
cp "$HERE/java/ClaimsStub.java" "$WORK/"
docker run -d --name "$CLAIMS" --network "$NET" --label "$LABEL" --entrypoint sleep "$JDK_IMAGE" 3600 >/dev/null
docker exec "$CLAIMS" mkdir -p /w
docker cp "$(dpath "$WORK/ClaimsStub.java")" "$CLAIMS:/w/ClaimsStub.java" >/dev/null
docker exec -d "$CLAIMS" sh -c 'cd /w && javac ClaimsStub.java && exec java -cp /w ClaimsStub 8080'
for i in $(seq 1 90); do helper wget -q -O - "http://$CLAIMS:8080/health" 2>/dev/null | grep -q '"ok"' && break; sleep 2; done

OWNER_PW=$(rand); RUNTIME_PW=$(rand); JWT_KEY=$(rand); CLAIMS_SECRET=$(rand)
docker run -d --name "$PG" --network "$NET" --label "$LABEL" -e POSTGRES_PASSWORD="$(rand)" "$PG_IMAGE" >/dev/null
docker run -d --name "$REDIS" --network "$NET" --label "$LABEL" "$REDIS_IMAGE" >/dev/null
# The image starts a temporary server during initdb, then restarts; wait for two successful queries in a row.
pg_ready() { docker exec "$PG" psql -U postgres -X -A -t -c 'select 1' >/dev/null 2>&1; }
for i in $(seq 1 90); do pg_ready && break; sleep 1; done
sleep 4
for i in $(seq 1 90); do pg_ready && break; sleep 1; done

# roles, database, schema owned by the migration role; runtime role gets no ownership
docker exec -i "$PG" psql -U postgres -X -v ON_ERROR_STOP=1 \
  -v owner_pw="$OWNER_PW" -v runtime_pw="$RUNTIME_PW" -f - < "$HERE/sql/init.sql" >/dev/null 2>"$WORK/init.err" \
  && result "preflight:roles" PASS "identity_owner (migration, owns schema identity) and identity_runtime (no DDL) created" \
  || { result "preflight:roles" FAIL "role/database setup failed: $(redact < "$WORK/init.err" | head -n 2)"; exit 1; }
PGVER=$(docker exec "$PG" psql -U postgres -X -A -t -c 'SHOW server_version' 2>/dev/null | tr -d '\r')
result "preflight:postgres" PASS "PostgreSQL server_version $PGVER (DEV is Aurora PostgreSQL 16.x)"

# throwaway BCrypt hashes from the Core jar's spring-security-crypto (cost 10), computed in a JDK container
docker create --name "$RUN-extract" --label "$LABEL" "$PREV_REF" >/dev/null
docker cp "$RUN-extract:/app/app.jar" "$(dpath "$WORK/app.jar")" >/dev/null && docker rm -f "$RUN-extract" >/dev/null
cp "$HERE/java/BcryptGen.java" "$WORK/"
# One JDK container for all three hashes. Files are copied into the container (docker cp), so extraction and
# compilation run on the container filesystem rather than a host bind mount (much faster on Docker Desktop).
HC="$RUN-jdk"
docker run -d --name "$HC" --label "$LABEL" --entrypoint sleep "$JDK_IMAGE" 900 >/dev/null
docker exec "$HC" mkdir -p /w
docker cp "$(dpath "$WORK/app.jar")" "$HC:/w/app.jar" 2>"$WORK/hash.err"
docker cp "$(dpath "$WORK/BcryptGen.java")" "$HC:/w/BcryptGen.java" 2>>"$WORK/hash.err"
ALL_HASHES=$(timeout 900 docker exec -e PW1="rb-pw-one-111" -e PW2="rb-pw-two-222" -e PW3="rb-pw-three-333" "$HC" sh -c '
    cd /w && jar xf app.jar BOOT-INF/lib &&
    CP=$(ls /w/BOOT-INF/lib/*.jar | tr "\n" ":") &&
    mkdir -p /w/out && javac -cp "$CP" -d /w/out /w/BcryptGen.java &&
    for p in "$PW1" "$PW2" "$PW3"; do java -cp "/w/out:$CP" BcryptGen "$p"; done' 2>"$WORK/hash.err")
docker rm -f "$HC" >/dev/null 2>&1
HASH_ONE=$(printf '%s\n' "$ALL_HASHES" | sed -n 1p); HASH_TWO=$(printf '%s\n' "$ALL_HASHES" | sed -n 2p); HASH_THREE=$(printf '%s\n' "$ALL_HASHES" | sed -n 3p)
case "$HASH_ONE" in '$2a$'*) result "preflight:bcrypt" PASS "throwaway BCrypt hashes generated in $JDK_IMAGE" ;;
  *) result "preflight:bcrypt" FAIL "BCrypt generation failed"; exit 1 ;;
esac
export PG REDIS

# ---------- 1. previous Core on an empty database: applies V1, V2 ----------
start_core "$CORE_PREV" "$PREV_REF" migrator
if wait_core "$CORE_PREV"; then
  H=$(pgq identity_owner "SELECT string_agg(version || ':' || success, ' ' ORDER BY installed_rank) FROM identity.flyway_schema_history;")
  result "1" PASS "previous Core ($PREV_REF) started on empty DB; history: $H"
  note "$(core_log_cause "$CORE_PREV" 'Successfully applied|Current version of schema')"
else
  result "1" FAIL "previous Core did not start on empty DB: $(core_log_cause "$CORE_PREV" 'ERROR|Caused by' | head -n 2)"
fi
rm_core "$CORE_PREV"

# ---------- 2a. new Core with the RUNTIME role only, V3 pending ----------
start_core "$CORE_NEW" "$NEW_REF" runtime
if wait_core "$CORE_NEW"; then
  result "2a" FAIL "new Core started with runtime-only config while V3 is pending (expected failure)"
else
  C=$(core_log_cause "$CORE_NEW" 'denied|must be owner|Caused by|Migration .* failed|FlywayException' | head -n 2)
  V3=$(pgq identity_owner "SELECT count(*) FROM identity.flyway_schema_history WHERE version = '3';")
  if [ "$V3" = 0 ]; then result "2a" PASS "runtime-only new Core fails before V3 is applied (expected); V3 rows = 0"
  else result "2a" FAIL "V3 applied by runtime-only start"; fi
  note "$C"
fi
rm_core "$CORE_NEW"

# ---------- 2a2. runtime role WITH SELECT on the history table (test-only grant), V3 still pending ----------
# Separates the two possible needs: read access to flyway_schema_history, and DDL for a pending migration.
pgq identity_owner "GRANT SELECT ON identity.flyway_schema_history TO identity_runtime;" >/dev/null
start_core "$CORE_NEW" "$NEW_REF" runtime
if wait_core "$CORE_NEW"; then
  result "2a2" FAIL "runtime role with history SELECT started while V3 was pending"
else
  R2A=$(root_cause "$CORE_NEW")
  if printf '%s' "$R2A" | grep -q 'must be owner\|permission denied for table password_credentials\|permission denied for schema'; then
    result "2a2" PASS "with history SELECT granted, a pending V3 fails on DDL (not on the history read)"
  else result "2a2" FAIL "unexpected root cause with history SELECT granted"; fi
  note "root: $R2A"
fi
rm_core "$CORE_NEW"
pgq identity_owner "REVOKE SELECT ON identity.flyway_schema_history FROM identity_runtime;" >/dev/null

# ---------- 2b. new Core with the MIGRATION role: V3 applied ----------
start_core "$CORE_NEW" "$NEW_REF" migrator
if wait_core "$CORE_NEW"; then
  R=$(pgq identity_owner "SELECT installed_rank || ' v' || version || ' ' || description || ' success=' || success || ' checksum=' || checksum FROM identity.flyway_schema_history WHERE version = '3';")
  T=$(pgq identity_owner "SELECT count(*) FROM information_schema.columns WHERE table_schema='identity' AND table_name='password_credentials' AND column_name='credential_revision';")
  if [ -n "$R" ] && [ "$T" = 1 ]; then result "2b" PASS "new Core applied V3 with migration role; history: $R"
  else result "2b" FAIL "V3 not recorded after new Core start"; fi
  note "$(core_log_cause "$CORE_NEW" 'Successfully applied|Migrating schema')"
else
  result "2b" FAIL "new Core with migration role did not start: $(core_log_cause "$CORE_NEW" 'ERROR|Caused by' | head -n 2)"
fi
V3_RANK=$(pgq identity_owner "SELECT installed_rank FROM identity.flyway_schema_history WHERE version='3';")
V3_SUM=$(pgq identity_owner "SELECT checksum FROM identity.flyway_schema_history WHERE version='3';")

# ---------- 2c. after V3: runtime-only start (no pending migration) ----------
rm_core "$CORE_NEW"
start_core "$CORE_NEW" "$NEW_REF" runtime
if wait_core "$CORE_NEW"; then
  result "2c" PASS "runtime-only new Core starts with V3 applied (no pending migration)"
else
  R2C=$(root_cause "$CORE_NEW")
  if printf '%s' "$R2C" | grep -q 'flyway_schema_history'; then result "2c" PASS "runtime-only start after V3 fails on the history read (expected without SELECT)"
  else result "2c" FAIL "runtime-only start after V3 fails for an unexpected reason"; fi
  note "root: $R2C"
fi
rm_core "$CORE_NEW"

# ---------- 2c2. runtime role WITH history SELECT, nothing pending: does startup need DDL? ----------
pgq identity_owner "GRANT SELECT ON identity.flyway_schema_history TO identity_runtime;" >/dev/null
start_core "$CORE_NEW" "$NEW_REF" runtime
if wait_core "$CORE_NEW"; then
  result "2c2" PASS "runtime-only start with history SELECT and nothing pending: starts"
else
  result "2c2" FAIL "runtime-only start with history SELECT and nothing pending does not come up"
  note "root: $(root_cause "$CORE_NEW")"
fi
rm_core "$CORE_NEW"
pgq identity_owner "REVOKE SELECT ON identity.flyway_schema_history FROM identity_runtime;" >/dev/null

# ---------- 4a. functional checks, new Core on the V3 database (migration-role config) ----------
pgsql_seed() { # seed the throwaway account as the migration role
  printf '%s\n' "INSERT INTO platform_accounts (id, status, primary_email, created_at, updated_at) VALUES ('11111111-1111-4111-8111-111111111111','ACTIVE','rb-user-1@example.invalid', now(), now()) ON CONFLICT (id) DO NOTHING;" \
    "INSERT INTO password_credentials (account_id, login_id, password_hash, created_at, updated_at) VALUES ('11111111-1111-4111-8111-111111111111','rb-user-1', :'hash', now(), now()) ON CONFLICT (account_id) DO NOTHING;" > "$WORK/seed.sql"
  pgsql identity_owner "$WORK/seed.sql" -v hash="$HASH_ONE" >/dev/null
}
start_core "$CORE_NEW" "$NEW_REF" migrator
if wait_core "$CORE_NEW"; then
  pgsql_seed
  L=$(http POST "$CORE_NEW" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-one-111"}')
  S=$(status_of "$L"); ACCESS=$(json_field "$L" accessToken); REFRESH=$(json_field "$L" refreshToken)
  if [ "$S" = 200 ]; then result "4a.login" PASS "login (new Core, V3 DB): HTTP $S, tokens issued"
  else result "4a.login" FAIL "login HTTP ${S:-none}"; note "$(core_log_cause "$CORE_NEW" 'ERROR|WARN|Exception' | head -n 3)"; fi
  RF=$(http POST "$CORE_NEW" /api/v1/auth/refresh "{\"refreshToken\":\"$REFRESH\"}")
  S=$(status_of "$RF"); R2=$(json_field "$RF" refreshToken)
  [ "$S" = 200 ] && result "4a.refresh" PASS "token refresh (new Core): HTTP $S, new refresh token issued" || result "4a.refresh" FAIL "refresh HTTP ${S:-none}"
  pgq identity_owner "UPDATE password_credentials SET password_hash = '$HASH_TWO', updated_at = now() WHERE login_id = 'rb-user-1';" >/dev/null 2>&1
  REV=$(pgq identity_owner "SELECT credential_revision FROM password_credentials WHERE login_id = 'rb-user-1';")
  OLD=$(http POST "$CORE_NEW" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-one-111"}'); S_OLD=$(status_of "$OLD")
  NEWL=$(http POST "$CORE_NEW" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-two-222"}'); S_NEW=$(status_of "$NEWL")
  if [ "$S_OLD" != 200 ] && [ "$S_NEW" = 200 ] && [ "$REV" = 1 ]; then
    result "4a.password" PASS "password change via DB (new Core): credential_revision 0->$REV (trigger), old password HTTP $S_OLD, new HTTP $S_NEW"
  else result "4a.password" FAIL "password change: revision=$REV old=$S_OLD new=$S_NEW"; fi
else
  result "4a" FAIL "new Core not healthy on V3 DB: $(core_log_cause "$CORE_NEW" 'ERROR|Caused by' | head -n 2)"
fi
rm_core "$CORE_NEW"

# ---------- 3. rollback: previous Core on the V3 database ----------
# 3.migrator: previous image, migration role, default Flyway settings. Measures whether it starts on the V3 database.
start_core "$CORE_PREV" "$PREV_REF" migrator
if wait_core "$CORE_PREV"; then
  result "3.migrator" PASS "previous Core STARTS on the V3 database with default Flyway settings (not blocked)"
  note "$(core_log_cause "$CORE_PREV" 'Successfully validated|Current version of schema|not resolved|Validate failed' | head -n 3)"
  # functional checks on the previous Core, while it is running (same data as step 4a)
  L=$(http POST "$CORE_PREV" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-two-222"}'); S=$(status_of "$L"); RT=$(json_field "$L" refreshToken)
  if [ "$S" = 200 ]; then result "4b.login" PASS "login (previous Core, V3 DB): HTTP $S"; else result "4b.login" FAIL "login (previous Core, V3 DB): HTTP ${S:-none}"; note "$(core_log_cause "$CORE_PREV" 'ERROR|WARN|Exception' | head -n 3)"; fi
  RF=$(http POST "$CORE_PREV" /api/v1/auth/refresh "{\"refreshToken\":\"$RT\"}"); S=$(status_of "$RF")
  if [ "$S" = 200 ]; then result "4b.refresh" PASS "token refresh (previous Core): HTTP $S"; else result "4b.refresh" FAIL "token refresh (previous Core): HTTP ${S:-none}"; fi
  pgq identity_owner "UPDATE password_credentials SET password_hash = '$HASH_THREE', updated_at = now() WHERE login_id = 'rb-user-1';" >/dev/null 2>&1
  REV=$(pgq identity_owner "SELECT credential_revision FROM password_credentials WHERE login_id = 'rb-user-1';")
  S3=$(status_of "$(http POST "$CORE_PREV" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-three-333"}')")
  S2=$(status_of "$(http POST "$CORE_PREV" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-two-222"}')")
  if [ "$S3" = 200 ] && [ "$S2" != 200 ]; then result "4b.password" PASS "password change (previous Core): revision now $REV, new password HTTP $S3, old HTTP $S2"
  else result "4b.password" FAIL "password change (previous Core): new=$S3 old=$S2 revision=$REV"; fi
  PREV_OK=1
else
  result "3.migrator" FAIL "previous Core does not start on the V3 database with default Flyway settings"
  note "root: $(root_cause "$CORE_PREV")"
  PREV_OK=0
fi
rm_core "$CORE_PREV"

# 3.ignore-future: the explicit form of Flyway's default (future migrations tolerated) must start.
start_core "$CORE_PREV" "$PREV_REF" migrator SPRING_FLYWAY_IGNORE_MIGRATION_PATTERNS='*:future'
if wait_core "$CORE_PREV"; then
  result "3.ignore-future" PASS "previous Core starts on V3 DB with SPRING_FLYWAY_IGNORE_MIGRATION_PATTERNS=*:future"
else
  result "3.ignore-future" FAIL "previous Core blocked with *:future: $(root_cause "$CORE_PREV" | head -n 1)"
fi
rm_core "$CORE_PREV"

# 3.override-missing-only (measurement): replacing the default with *:missing removes the future tolerance.
start_core "$CORE_PREV" "$PREV_REF" migrator SPRING_FLYWAY_IGNORE_MIGRATION_PATTERNS='*:missing'
if wait_core "$CORE_PREV"; then
  result "3.override-missing-only" FAIL "previous Core started with *:missing only (expected Flyway to block)"
else
  C=$(core_log_cause "$CORE_PREV" 'not resolved locally' | head -n 1)
  if [ -n "$C" ]; then result "3.override-missing-only" PASS "blocked as observed: overriding the default removes the future tolerance"; note "$C"
  else result "3.override-missing-only" FAIL "not blocked by Flyway validation; see log"; fi
fi
rm_core "$CORE_PREV"
PREV_OK=1

# 3c. runtime-only start of the previous image on V3 DB (history read denied, as in 2c)
rm_core "$CORE_PREV"
start_core "$CORE_PREV" "$PREV_REF" runtime
if wait_core "$CORE_PREV"; then result "3.runtime" PASS "previous Core starts with runtime-only config on V3 DB"
else
  R3R=$(root_cause "$CORE_PREV")
  if printf '%s' "$R3R" | grep -q 'flyway_schema_history'; then result "3.runtime" PASS "previous Core runtime-only start on V3 DB fails on the history read (expected without SELECT)"
  else result "3.runtime" FAIL "previous Core runtime-only start fails for an unexpected reason"; fi
  note "root: $R3R"
fi
rm_core "$CORE_PREV"


# data snapshot after the previous Core has run on the database (counts only, no values)
COUNTS_BEFORE=$(pgq identity_owner "SELECT (SELECT count(*) FROM identity.platform_accounts)||','||(SELECT count(*) FROM identity.password_credentials)||','||(SELECT count(*) FROM identity.refresh_token);")

# ---------- 5. switch back to the new Core on the same database ----------
start_core "$CORE_NEW" "$NEW_REF" migrator
if wait_core "$CORE_NEW"; then
  R2=$(pgq identity_owner "SELECT installed_rank || ' v' || version || ' checksum=' || checksum FROM identity.flyway_schema_history WHERE version='3';")
  N3=$(pgq identity_owner "SELECT count(*) FROM identity.flyway_schema_history WHERE version='3';")
  RANK_OK=0; [ "$R2" = "$V3_RANK v3 checksum=$V3_SUM" ] && RANK_OK=1
  RUN_LINE=$(docker logs "$CORE_NEW" 2>&1 | grep -c 'Migrating schema' || true)
  COUNTS_AFTER=$(pgq identity_owner "SELECT (SELECT count(*) FROM identity.platform_accounts)||','||(SELECT count(*) FROM identity.password_credentials)||','||(SELECT count(*) FROM identity.refresh_token);")
  if [ "$N3" = 1 ] && [ "$RANK_OK" = 1 ] && [ "${RUN_LINE:-0}" = 0 ] && [ "$COUNTS_AFTER" = "$COUNTS_BEFORE" ]; then
    result "5.no-rerun" PASS "new Core restarted: V3 not re-applied (rows=$N3, same rank and checksum), data counts unchanged ($COUNTS_AFTER)"
  else
    result "5.no-rerun" FAIL "rerun/ data check: v3_rows=$N3 same_rank=$RANK_OK migrating_lines=${RUN_LINE:-?} counts before=$COUNTS_BEFORE after=$COUNTS_AFTER"
  fi
  L=$(http POST "$CORE_NEW" /api/v1/auth/login '{"userId":"rb-user-1","password":"rb-pw-three-333"}'); S=$(status_of "$L")
  [ "$S" = 200 ] && result "5.login" PASS "login (new Core after rollback cycle): HTTP $S" || result "5.login" FAIL "login HTTP ${S:-none}"
else
  result "5.no-rerun" FAIL "new Core did not restart on the used database: $(core_log_cause "$CORE_NEW" 'ERROR|Caused by' | head -n 2)"
fi
rm_core "$CORE_NEW"
result "5.registration-retry" SKIP "not run: enrollment client accepts only https (or loopback) and the Carelog enrollment endpoint is not available in this isolated network; see evidence-core-rollback-test.md"

echo
if [ "$FAILS" -eq 0 ]; then echo "RESULT: no FAIL ($FAILS failures)"; exit 0; fi
echo "RESULT: $FAILS FAIL"; exit 1
