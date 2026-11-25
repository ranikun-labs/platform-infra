#!/bin/sh
# Functional test of the front proxy, host mode. Uses the SAME nginx template and the SAME entrypoint as the image;
# only the network is simulated with loopback addresses:
#   carelog-be stand-in  127.0.0.1:8080  (bound to loopback only, like SERVER_ADDRESS=127.0.0.1)
#   task IP (proxy)      127.0.0.2       (8080 plain front, 8443 TLS)
#   ECS metadata stub    127.0.0.1:19000 (returns 127.0.0.2 as the task IPv4)
# Requires: nginx, openssl, jq, wget, curl, keytool and a JDK (java/javac) on the host, sudo-free except one
# /etc/hosts line for the JDK client (added and removed by this script; skipped if not writable).
# Usage: test-proxy-host.sh <workdir>   Evidence lines go to <workdir>/evidence.txt.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:?usage: test-proxy-host.sh <workdir>}
NG=$(command -v nginx) || { echo "nginx not found"; exit 1; }
JH=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
TASK_IP=127.0.0.2
META_PORT=19000
SAN=carelog-dev.test.internal
UUID=3f2b1c9e-8a7d-4e6b-9c1a-5d4e3f2a1b0c
PKI=$WORK/pki
TAG=tlsfront-host-$$
EVIDENCE=$WORK/evidence.txt
PASSES=0
FAILS=0
ENROLL="/api/v1/internal/v1/identity/carelog/enrollments/$UUID"
CLAIMS="/api/v1/internal/identity/claims/$UUID"
AUTH="Authorization: Bearer 0123456789abcdef0123456789abcdef"
CORE_HDR="X-Service-Id: platform-identity"
TLS="--cacert $PKI/ca.crt --resolve $SAN:8443:$TASK_IP"

mkdir -p "$WORK/stub" "$WORK/meta" "$WORK/proxy/nginx/conf.d" "$WORK/proxy/nginx/templates" "$WORK/proxy/tls"
: > "$EVIDENCE"
PROXY_PID=""

log() { echo "$*" | tee -a "$EVIDENCE"; }

stop_proxy() {
  if [ -n "$PROXY_PID" ]; then kill "$PROXY_PID" 2>/dev/null || true; wait "$PROXY_PID" 2>/dev/null || true; PROXY_PID=""; fi
}

cleanup() {
  stop_proxy
  for p in "$WORK/stub/nginx.pid" "$WORK/meta/nginx.pid"; do
    [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null || true
  done
  sed -i "/# $TAG\$/d" /etc/hosts 2>/dev/null || true
}
trap cleanup EXIT INT TERM

check() {  # name expected_code curl-args...
  name=$1; want=$2; shift 2
  got=$(curl --noproxy '*' --path-as-is -s -o "$WORK/body" -w '%{http_code}' "$@" 2>"$WORK/err" || true)
  body=$(head -c 160 "$WORK/body" 2>/dev/null | tr -d '\n')
  if [ "$got" = "$want" ]; then
    PASSES=$((PASSES + 1)); log "PASS [$name] http=$got body=${body:-<none>}"
  else
    FAILS=$((FAILS + 1)); log "FAIL [$name] want=$want got=${got:-none} err=$(head -c 160 "$WORK/err" | tr -d '\n') body=${body:-<none>}"
  fi
}

check_fail() {  # name curl-args...  (client-side TLS refusal expected)
  name=$1; shift
  if curl --noproxy '*' -s -o /dev/null "$@" 2>"$WORK/err"; then
    FAILS=$((FAILS + 1)); log "FAIL [$name] curl succeeded, a refusal was expected"
  else
    PASSES=$((PASSES + 1)); log "PASS [$name] refused: $(head -c 140 "$WORK/err" | tr -d '\n')"
  fi
}

wait_port() {  # url
  i=0
  until curl --noproxy '*' -s -o /dev/null "$1" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 30 ] && return 1; sleep 0.5
  done
}

start_nginx() {  # conf-file (daemon off assumed)  -> background, sets pid via file
  "$NG" -c "$1" -t >/dev/null 2>&1 || { log "FAIL nginx -t for $1"; FAILS=$((FAILS + 1)); return 1; }
}

echo "== generate test PKI"
sh "$HERE/tests/gen-material.sh" "$PKI" || exit 1

echo "== carelog-be stand-in on 127.0.0.1:8080 (echo)"
sed -e "s|__PID__|$WORK/stub/nginx.pid|" -e "s|__ERRLOG__|$WORK/stub/error.log|" \
  "$HERE/tests/stub-upstream.conf" > "$WORK/stub/nginx.conf"
start_nginx "$WORK/stub/nginx.conf" || exit 1
"$NG" -c "$WORK/stub/nginx.conf" &
sleep 1

echo "== ECS metadata stub on 127.0.0.1:$META_PORT"
sed -e "s|__PID__|$WORK/meta/nginx.pid|" -e "s|__ERRLOG__|$WORK/meta/error.log|" -e "s|__IP__|$TASK_IP|" \
  "$HERE/tests/metadata.conf.template" > "$WORK/meta/nginx.conf"
"$NG" -c "$WORK/meta/nginx.conf" &
sleep 1

# Prefix config for the proxy: the stock image nginx.conf reduced to what the entrypoint needs.
cat > "$WORK/proxy/nginx/nginx.conf" <<EOF
pid $WORK/proxy/nginx.pid;
error_log $WORK/proxy/error.log;
events { worker_connections 256; }
http {
    access_log off;
    include $WORK/proxy/nginx/conf.d/*.conf;
}
EOF
cp "$HERE/proxy/nginx.conf.template" "$WORK/proxy/nginx/templates/carelog-tls.conf.template"

start_proxy() {  # claims_on_8080 (true|false)
  stop_proxy
  rm -f "$WORK/proxy/nginx.pid"
  env ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT" \
    TLS_EXPECTED_DNS_SAN="$SAN" TLS_BUNDLE_JSON="$(jq -c . "$PKI/bundle-good.json")" \
    CORE_CLAIMS_ON_8080="$1" CARELOG_NGINX_DIR="$WORK/proxy/nginx" CARELOG_TLS_RUN_DIR="$WORK/proxy/tls" \
    sh "$HERE/proxy/proxy-entrypoint.sh" >"$WORK/proxy/entry.log" 2>&1 &
  PROXY_PID=$!
  i=0
  until grep -q 'proxy-entrypoint: ready' "$WORK/proxy/entry.log" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 40 ] && { cat "$WORK/proxy/entry.log"; return 1; }
    kill -0 "$PROXY_PID" 2>/dev/null || { cat "$WORK/proxy/entry.log"; return 1; }
    sleep 0.25
  done
  sleep 0.5
}

java_checks() {
  if ! grep -q "$SAN" /etc/hosts 2>/dev/null; then
    printf '%s %s # %s\n' "$TASK_IP" "$SAN" "$TAG" >> /etc/hosts 2>/dev/null \
      || { log "SKIP java checks: /etc/hosts not writable"; return; }
  fi
  mkdir -p "$WORK/trust"
  CARELOG_CA_BUNDLE="$PKI/ca-bundle.pem" CARELOG_TRUST_DIR="$WORK/trust" JAVA_HOME="$JH" \
    sh "$HERE/trust-init/trust-init.sh" >"$WORK/trust-init.log" 2>&1 \
    || { log "FAIL [trust-init on host JDK] $(tail -1 "$WORK/trust-init.log")"; FAILS=$((FAILS + 1)); return; }
  TS="$WORK/trust/cacerts"
  jrun() {  # name want-exit METHOD URL truststore|- expect [headers]
    name=$1; want=$2; shift 2
    out=$(env -u JAVA_TOOL_OPTIONS "$JH/bin/java" "$HERE/tests/TlsClient.java" "$@" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then
      PASSES=$((PASSES + 1)); log "PASS [java: $name] $(printf '%s' "$out" | head -1)"
    else
      FAILS=$((FAILS + 1)); log "FAIL [java: $name] rc=$rc want=$want $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fi
  }
  jrun "new Core enrollment PUT 8443 (TLS, SAN and hostname verified)" 0 PUT "https://$SAN:8443$ENROLL" "$TS" 200 "Authorization=Bearer 0123456789abcdef0123456789abcdef"
  jrun "new Core claims GET 8443 (TLS, SAN and hostname verified)" 0 GET "https://$SAN:8443$CLAIMS" "$TS" 200 "X-Service-Id=platform-identity"
  jrun "new Core enrollment via 8080 refused" 0 PUT "http://$TASK_IP:8080$ENROLL" "-" 403 "Authorization=Bearer 0123456789abcdef0123456789abcdef"
  jrun "old Core claims GET over http 8080 (rollback path)" 0 GET "http://$TASK_IP:8080$CLAIMS" "-" 200 "X-Service-Id=platform-identity"
  jrun "JDK default truststore rejects test CA" 2 GET "https://$SAN:8443$CLAIMS" "-" 200
}

run_suite() {  # claims_on_8080
  CLAIMS_ON=$1
  log ""
  log "### suite: CORE_CLAIMS_ON_8080=$CLAIMS_ON (task IP $TASK_IP)"
  start_proxy "$CLAIMS_ON" || { log "FAIL proxy did not start"; FAILS=$((FAILS + 1)); return; }
  wait_port "http://$TASK_IP:8080/api/v1/users/user-id/x" || log "WARN 8080 front not answering"

  [ "$CLAIMS_ON" = true ] && java_checks

  log "-- 8443 TLS listener (Core: enrollment PUT + claims GET only)"
  check "8443 enrollment PUT ok" 200 $TLS -X PUT -H "$AUTH" -H 'Content-Type: application/json' -d '{}' "https://$SAN:8443$ENROLL"
  check "8443 claims GET ok" 200 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS"
  check "8443 enrollment GET denied" 403 $TLS "https://$SAN:8443$ENROLL"
  check "8443 claims PUT denied" 403 $TLS -X PUT "https://$SAN:8443$CLAIMS"
  check "8443 gateway path denied" 403 $TLS "https://$SAN:8443/api/v1/users/user-id/x"
  check "8443 non-UUID accountId denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/v1/identity/carelog/enrollments/abc"
  check "8443 bypass /internal/x//enrollments denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/x//enrollments/$UUID"
  check "8443 bypass //v1 denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/v1//identity/carelog/enrollments/$UUID"
  check "8443 encoded slash denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/v1/identity/carelog/enrollments%2F$UUID"
  check "8443 path parameter ; denied" 403 $TLS -X PUT "https://$SAN:8443$ENROLL;x=1"
  check "8443 dot segment denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/x/../v1/identity/carelog/enrollments/$UUID"
  check "8443 trailing slash denied" 403 $TLS -X PUT "https://$SAN:8443$ENROLL/"
  check "8443 encoded internal segment denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/%69nternal/v1/identity/carelog/enrollments/$UUID"
  check "8443 plain HTTP not served" 400 -X PUT "http://$TASK_IP:8443$ENROLL"
  check_fail "client without test CA refuses 8443" --resolve "$SAN:8443:$TASK_IP" "https://$SAN:8443$CLAIMS"
  check_fail "client refuses wrong hostname" --cacert "$PKI/ca.crt" --resolve "other.test.internal:8443:$TASK_IP" "https://other.test.internal:8443$CLAIMS"

  log "-- 8080 front (Gateway pass-through; enrollment never; claims per CORE_CLAIMS_ON_8080)"
  check "8080 enrollment PUT denied" 403 -X PUT -H "$AUTH" "http://$TASK_IP:8080$ENROLL"
  check "8080 enrollment bypass denied" 403 -X PUT -H "$AUTH" "http://$TASK_IP:8080/api/v1/internal/x//enrollments/$UUID"
  check "8080 enrollment // prefix denied" 403 -X PUT -H "$AUTH" "http://$TASK_IP:8080//api/v1/internal/v1/identity/carelog/enrollments/$UUID"
  check "8080 encoded internal denied" 403 -X PUT -H "$AUTH" "http://$TASK_IP:8080/api/v1/%69nternal/v1/identity/carelog/enrollments/$UUID"
  check "8080 case variant internal denied" 403 -X PUT -H "$AUTH" "http://$TASK_IP:8080/api/v1/Internal/v1/identity/carelog/enrollments/$UUID"
  check "8080 gateway GET passes" 200 "http://$TASK_IP:8080/api/v1/users/user-id/abc"
  check "8080 gateway POST passes" 200 -X POST -H 'Content-Type: application/json' -d '{}' "http://$TASK_IP:8080/api/v1/users/managers"
  check "8080 other internal path denied" 403 -H "$CORE_HDR" "http://$TASK_IP:8080/api/v1/internal/identity/other/$UUID"
  check "8080 non-api path denied" 403 "http://$TASK_IP:8080/rag/anything"
  check "8080 claims with trailing segment denied" 403 -H "$CORE_HDR" "http://$TASK_IP:8080$CLAIMS/extra"
  if [ "$CLAIMS_ON" = true ]; then
    check "8080 claims GET ok (transition, old Core)" 200 -H "$CORE_HDR" "http://$TASK_IP:8080$CLAIMS"
    check "8080 claims PUT denied" 403 -X PUT -H "$CORE_HDR" "http://$TASK_IP:8080$CLAIMS"
  else
    check "8080 claims closed after rollback window" 403 -H "$CORE_HDR" "http://$TASK_IP:8080$CLAIMS"
    check "8443 claims still ok after rollback window" 200 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS"
    check "8080 gateway GET still passes after window" 200 "http://$TASK_IP:8080/api/v1/users/user-id/abc"
  fi

  log "-- listener scope"
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):(8080|8443)$' >/dev/null; then
    FAILS=$((FAILS + 1)); log "FAIL [wildcard listener on 8080/8443]"
  else
    PASSES=$((PASSES + 1)); log "PASS [no wildcard listener on 8080/8443]"
  fi
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qx '127.0.0.1:8080'; then
    PASSES=$((PASSES + 1)); log "PASS [carelog stand-in bound to 127.0.0.1:8080 only]"
  else
    FAILS=$((FAILS + 1)); log "FAIL [127.0.0.1:8080 listener missing]"
  fi
  grep -E '\[(emerg|crit|alert)\]' "$WORK/proxy/error.log" >/dev/null 2>&1 && { FAILS=$((FAILS + 1)); log "FAIL [nginx emerg/crit]"; }
  stop_proxy
}

run_suite true
run_suite false

log ""
log "SUMMARY pass=$PASSES fail=$FAILS"
[ "$FAILS" -eq 0 ]
