#!/bin/sh
# Functional test of the front proxy, host mode. Uses the SAME nginx template and the SAME entrypoint as the image;
# only the network is simulated with loopback addresses:
#   carelog-be stand-in  127.0.0.1:8080  (upstream of the proxy; loopback, as the app sees Core traffic)
#   task IP (proxy)      127.0.0.2:8443  (TLS only)
#   ECS metadata stub    127.0.0.1:19000 (returns 127.0.0.2 as the task IPv4)
# Not covered here: the app's 0.0.0.0:8080 bind for Gateway and the app-side loopback check on internal endpoints.
# Those are carelog-be tests. This suite proves only that the proxy never listens on the task IP:8080.
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
JSON_CT='Content-Type: application/json'

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
  rm -f "$WORK/body"
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

check_deny_json() {  # name curl-args...  (a 403 must carry the JSON body and content type)
  name=$1; shift
  ct=$(curl --noproxy '*' --path-as-is -s -o "$WORK/body" -w '%{content_type}' "$@" 2>/dev/null || true)
  if [ "$ct" = application/json ] && grep -q '"error":"forbidden"' "$WORK/body"; then
    PASSES=$((PASSES + 1)); log "PASS [$name] content-type=$ct body=$(tr -d '\n' < "$WORK/body")"
  else
    FAILS=$((FAILS + 1)); log "FAIL [$name] content-type=${ct:-none} body=$(head -c 120 "$WORK/body" | tr -d '\n')"
  fi
}

wait_tls() {  # 8443 answers (any HTTP status) once nginx is up
  i=0
  until curl --noproxy '*' -s -o /dev/null $TLS "https://$SAN:8443/api/v1/x" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 30 ] && return 1; sleep 0.5
  done
}

echo "== generate test PKI"
sh "$HERE/tests/gen-material.sh" "$PKI" || exit 1

echo "== carelog-be stand-in on 127.0.0.1:8080 (echo; the proxy upstream)"
sed -e "s|__PID__|$WORK/stub/nginx.pid|" -e "s|__ERRLOG__|$WORK/stub/error.log|" \
  "$HERE/tests/stub-upstream.conf" > "$WORK/stub/nginx.conf"
"$NG" -c "$WORK/stub/nginx.conf" -t >/dev/null 2>&1 || { echo "FAIL stub config"; exit 1; }
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

start_proxy() {
  stop_proxy
  rm -f "$WORK/proxy/nginx.pid"
  env ECS_CONTAINER_METADATA_URI_V4="http://127.0.0.1:$META_PORT" \
    TLS_EXPECTED_DNS_SAN="$SAN" TLS_BUNDLE_JSON="$(jq -c . "$PKI/bundle-twotier.json")" TLS_ROOT_CA_PEM="$(cat "$PKI/ca.crt")" \
    CARELOG_NGINX_DIR="$WORK/proxy/nginx" CARELOG_TLS_RUN_DIR="$WORK/proxy/tls" \
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
  # The JDK sends Host: <name>:8443. The Host check must accept it (port is dropped by $host).
  jrun "new Core enrollment PUT 8443 (TLS, SAN and hostname verified, Host with port)" 0 PUT "https://$SAN:8443$ENROLL" "$TS" 200 "Authorization=Bearer 0123456789abcdef0123456789abcdef"
  jrun "new Core claims GET 8443 (TLS, SAN and hostname verified)" 0 GET "https://$SAN:8443$CLAIMS" "$TS" 200 "X-Service-Id=platform-identity"
  jrun "JDK default truststore rejects test CA" 2 GET "https://$SAN:8443$CLAIMS" "-" 200
}

log "### proxy suite (task IP $TASK_IP, upstream 127.0.0.1:8080)"
start_proxy || { log "FAIL proxy did not start"; FAILS=$((FAILS + 1)); exit 1; }
wait_tls || log "WARN 8443 not answering"

java_checks

log "-- 8443 allowed paths (Core: enrollment PUT and claims GET)"
check "enrollment PUT ok" 200 $TLS -X PUT -H "$AUTH" -H "$JSON_CT" -d '{}' "https://$SAN:8443$ENROLL"
check "claims GET ok" 200 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS"
check "claims GET ok, query string passed (not checked)" 200 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS?cursor=;//..%2F&x=%0a"
check "enrollment PUT ok, query with ;// and .. passed" 200 $TLS -X PUT -H "$AUTH" -H "$JSON_CT" -d '{}' "https://$SAN:8443$ENROLL?x=;//../%0d"
check "Host with port of expected name ok" 200 $TLS -H "$CORE_HDR" -H "Host: $SAN:8443" "https://$SAN:8443$CLAIMS"

log "-- 8443 denied: method, path, and identifier"
check "enrollment GET denied" 403 $TLS "https://$SAN:8443$ENROLL"
check "claims PUT denied" 403 $TLS -X PUT "https://$SAN:8443$CLAIMS"
check "gateway path denied" 403 $TLS "https://$SAN:8443/api/v1/users/user-id/x"
check "non-UUID accountId denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/v1/identity/carelog/enrollments/abc"
check "other internal path denied" 403 $TLS -H "$CORE_HDR" "https://$SAN:8443/api/v1/internal/identity/other/$UUID"
check "bypass /internal/x//enrollments denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/x//enrollments/$UUID"
check "bypass //v1 denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/v1//identity/carelog/enrollments/$UUID"
check "encoded slash denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/v1/identity/carelog/enrollments%2F$UUID"
check "path parameter ; denied" 403 $TLS -X PUT "https://$SAN:8443$ENROLL;x=1"
check "dot segment .. denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/x/../v1/identity/carelog/enrollments/$UUID"
check "encoded dot segment %2e%2e denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/%2e%2e/v1/identity/carelog/enrollments/$UUID"
check "/./ segment denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/internal/./v1/identity/carelog/enrollments/$UUID"
check "trailing /. denied" 403 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS/."
check "trailing slash denied" 403 $TLS -X PUT "https://$SAN:8443$ENROLL/"
check "encoded internal segment denied" 403 $TLS -X PUT "https://$SAN:8443/api/v1/%69nternal/v1/identity/carelog/enrollments/$UUID"
check "UUID then %0a denied" 403 $TLS -X PUT -H "$AUTH" "https://$SAN:8443$ENROLL%0a"
check "UUID then %0d denied" 403 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS%0d"
check "fragment # in path denied" 403 $TLS --request-target "$CLAIMS#x" "https://$SAN:8443/"
check "UUID then %25 denied" 403 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS%25"
check "encoded %00 in path refused by nginx parser (400, never reaches app)" 400 $TLS -H "$CORE_HDR" "https://$SAN:8443$CLAIMS%00"
check_deny_json "403 carries JSON body" $TLS "https://$SAN:8443/api/v1/users/user-id/x"
check_json_ct() {  # name want-code want-content-type curl-args...  (status and content type, body must be JSON)
  name=$1; want=$2; wct=$3; shift 3
  rm -f "$WORK/body"
  got=$(curl --noproxy '*' --path-as-is -s -o "$WORK/body" -w '%{http_code} %{content_type}' "$@" 2>/dev/null || true)
  if [ "$got" = "$want $wct" ] && jq -e . "$WORK/body" >/dev/null 2>&1; then
    PASSES=$((PASSES + 1)); log "PASS [$name] $got body=$(tr -d '\n' < "$WORK/body")"
  else
    FAILS=$((FAILS + 1)); log "FAIL [$name] want='$want $wct' got='$got' body=$(head -c 120 "$WORK/body" | tr -d '\n')"
  fi
}
BIG=$(head -c 5000 /dev/zero | tr '\0' a)
check_json_ct "body over 4k -> 413 JSON" 413 application/json $TLS -X PUT -H "$AUTH" -H "$JSON_CT" -d "$BIG" "https://$SAN:8443$ENROLL"
check_json_ct "Host mismatch -> 421 JSON" 421 application/json $TLS -X PUT -H "$AUTH" -H "$JSON_CT" -H "Host: other.test.internal" -d '{}' "https://$SAN:8443$ENROLL"

log "-- 8443 Host and transport"
check "Host other name -> 421" 421 $TLS -X PUT -H "$AUTH" -H "$JSON_CT" -H "Host: other.test.internal" -d '{}' "https://$SAN:8443$ENROLL"
check "plain HTTP to 8443 not served" 400 -X PUT "http://$TASK_IP:8443$ENROLL"
check_fail "client without test CA refuses 8443" --resolve "$SAN:8443:$TASK_IP" "https://$SAN:8443$CLAIMS"
check_fail "client refuses wrong hostname" --cacert "$PKI/ca.crt" --resolve "other.test.internal:8443:$TASK_IP" "https://other.test.internal:8443$CLAIMS"

log "-- listener scope (no listener on 8080 from the proxy)"
check "no proxy listener on task IP:8080 (connection refused)" 000 "http://$TASK_IP:8080$CLAIMS"
if grep -Eq 'listen[[:space:]]+[^;]*8080' "$WORK/proxy/nginx/conf.d/default.conf"; then
  FAILS=$((FAILS + 1)); log "FAIL [rendered config has a listen on 8080]"
else
  PASSES=$((PASSES + 1)); log "PASS [rendered config has no listen on 8080]"
fi
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qx "$TASK_IP:8443"; then
  PASSES=$((PASSES + 1)); log "PASS [TLS listener bound to task IP:8443]"
else
  FAILS=$((FAILS + 1)); log "FAIL [task IP:8443 listener missing]"
fi
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\*|\[::\]):(8080|8443)$' >/dev/null; then
  FAILS=$((FAILS + 1)); log "FAIL [wildcard listener on 8080/8443]"
else
  PASSES=$((PASSES + 1)); log "PASS [no wildcard listener on 8080/8443]"
fi
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qx '127.0.0.1:8080'; then
  PASSES=$((PASSES + 1)); log "PASS [upstream stand-in bound to 127.0.0.1:8080 only]"
else
  FAILS=$((FAILS + 1)); log "FAIL [127.0.0.1:8080 listener missing]"
fi
grep -E '\[(emerg|crit|alert)\]' "$WORK/proxy/error.log" >/dev/null 2>&1 && { FAILS=$((FAILS + 1)); log "FAIL [nginx emerg/crit]"; }
stop_proxy

log ""
log "SUMMARY pass=$PASSES fail=$FAILS"
[ "$FAILS" -eq 0 ]
