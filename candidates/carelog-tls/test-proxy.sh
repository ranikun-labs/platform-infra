#!/bin/sh
# Local-only routing and health test for nginx.conf and the ECS healthCheck command.
#
# Usage:
#   inside the image (no arguments):  sh /tmp/test-proxy.sh          (the form used by run-all and README)
#   from a host with Docker:          sh test-proxy.sh <image-tag>   (mounts this file into the image, then runs it)
#
# busybox httpd stubs stand in for Carelog: 127.0.0.1:8080 (application) and 127.0.0.1:8081 (management).
# The 8080 stub returns 404 for every path, so "reached the backend" is observed as 404 (or 501 for methods
# the stub does not implement), and nginx's own refusal is observed as 403. No real credentials or AWS
# resources are involved. The management stub serves only /actuator/health/liveness (200).
set -eu

if [ "${1:-}" != "" ] && ! command -v nginx >/dev/null 2>&1; then
  dir=$(cd "$(dirname "$0")" && pwd)
  exec docker run --rm --entrypoint sh -v "$dir/$(basename "$0"):/tmp/test-proxy.sh:ro" "$1" /tmp/test-proxy.sh
fi

apk add --no-cache openssl curl busybox-extras >/dev/null
mkdir -p /run/carelog-tls /tmp/backend /tmp/mgmt/actuator/health
printf 'stub-ok\n' >/tmp/backend/index.html
printf 'UP\n' >/tmp/mgmt/actuator/health/liveness
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout /tmp/ca.key -out /tmp/ca.crt -subj /CN=test-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout /run/carelog-tls/server.key -out /tmp/server.csr -subj /CN=carelog.test >/dev/null 2>&1
printf 'subjectAltName=DNS:carelog.test\n' >/tmp/ext.cnf
openssl x509 -req -in /tmp/server.csr -CA /tmp/ca.crt -CAkey /tmp/ca.key -CAcreateserial -days 1 -extfile /tmp/ext.cnf -out /run/carelog-tls/server.crt >/dev/null 2>&1
TASK_IPV4=127.0.0.2 envsubst '${TASK_IPV4}' </etc/nginx/templates/carelog.conf >/etc/nginx/conf.d/default.conf
nginx -t
busybox-extras httpd -f -p 127.0.0.1:8080 -h /tmp/backend & APP_PID=$!
busybox-extras httpd -f -p 127.0.0.1:8081 -h /tmp/mgmt & MGMT_PID=$!
nginx
sleep 1

fail=0
# code <curl args...>: prints the HTTP status, or 000 when no response was received.
code() { curl -sS --noproxy '*' --path-as-is -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
# want_code <expected> <label> <curl args...>
want_code() {
  want=$1; label=$2; shift 2
  got=$(code "$@"); [ -n "$got" ] || got=000
  if [ "$got" = "$want" ]; then printf 'ok   %s -> %s\n' "$label" "$got"
  else printf 'FAIL %s -> %s (want %s)\n' "$label" "$got" "$want"; fail=1; fi
}
# reaches_backend <label> <curl args...>: any status except nginx's 403 and no-response 000.
reaches_backend() {
  label=$1; shift
  got=$(code "$@"); [ -n "$got" ] || got=000
  case "$got" in 000|403) printf 'FAIL %s -> %s (want backend reached)\n' "$label" "$got"; fail=1 ;;
    *) printf 'ok   %s -> %s\n' "$label" "$got" ;; esac
}
H=http://127.0.0.2:8080
S=https://carelog.test:8443
TLS="--resolve carelog.test:8443:127.0.0.2 --cacert /tmp/ca.crt"
ID=11111111-2222-3333-4444-555555555555
ENR=/api/v1/internal/v1/identity/carelog/enrollments/$ID

echo "== 8080 allowed (Gateway routes, Core claims)"
want_code 404 "GET customers" "$H/api/v1/users/customers"
reaches_backend "POST customers" -X POST "$H/api/v1/users/customers"
reaches_backend "PATCH customer item" -X PATCH "$H/api/v1/users/customers/$ID"
want_code 404 "GET customer-event item" "$H/api/v1/customer-events/$ID"
reaches_backend "POST customer-event occur" -X POST "$H/api/v1/customer-events/$ID/occur"
reaches_backend "POST customer-event cancel" -X POST "$H/api/v1/customer-events/$ID/cancel"
want_code 404 "GET relations by manager+customer" "$H/api/v1/relations/manager/$ID/customer/$ID"
want_code 404 "GET relations manager list" "$H/api/v1/relations/manager"
reaches_backend "PATCH relation status" -X PATCH "$H/api/v1/relations/$ID/status"
reaches_backend "DELETE relation" -X DELETE "$H/api/v1/relations/$ID"
want_code 404 "GET journals list" "$H/api/v1/relations/$ID/journals"
reaches_backend "PUT journal" -X PUT "$H/api/v1/relations/$ID/journals/$ID"
want_code 404 "GET journal history" "$H/api/v1/relations/$ID/journals/$ID/history"
want_code 404 "GET journal templates" "$H/api/v1/journal-templates"
reaches_backend "POST managers (public path)" -X POST "$H/api/v1/users/managers"
want_code 404 "GET users by email (encoded @)" "$H/api/v1/users/email/a%40example.invalid"
want_code 404 "GET users by user-id" "$H/api/v1/users/user-id/fixture-user"
reaches_backend "PATCH user" -X PATCH "$H/api/v1/users/$ID"
reaches_backend "DELETE user" -X DELETE "$H/api/v1/users/$ID"
want_code 404 "GET Core claims" "$H/api/v1/internal/identity/claims/$ID"
want_code 404 "GET Core claims with query" "$H/api/v1/internal/identity/claims/$ID?trace=1"
# HEAD is allowed wherever GET is (nginx limit_except GET implies HEAD); the method set is otherwise exact.
reaches_backend "HEAD customers (implied by GET)" -I "$H/api/v1/users/customers"
# Host header does not select a route: the 8080 listener is reached only from Gateway/Core security groups.
reaches_backend "GET customers with foreign Host header" -H "Host: attacker.invalid" "$H/api/v1/users/customers"

echo "== 8080 denied (method, path, encoding and normalization variants)"
want_code 403 "DELETE customers (method)" -X DELETE "$H/api/v1/users/customers"
want_code 403 "PUT customers (method)" -X PUT "$H/api/v1/users/customers/$ID"
want_code 403 "POST claims (method)" -X POST "$H/api/v1/internal/identity/claims/$ID"
want_code 403 "GET claims extra segment" "$H/api/v1/internal/identity/claims/$ID/x"
want_code 403 "PUT enrollment on 8080" -X PUT "$H$ENR"
want_code 403 "GET enrollment on 8080" "$H$ENR"
want_code 403 "GET internal path" "$H/api/v1/internal/v1/identity/carelog/enrollments/$ID"
want_code 403 "dot-dot into enrollment" "$H/api/v1/users/customers/../../internal/v1/identity/carelog/enrollments/$ID"
want_code 403 "encoded dot-dot" "$H/api/v1/users/customers/%2e%2e/internal/v1/identity/carelog/enrollments/$ID"
want_code 403 "tomcat ..; path-param" "$H/api/v1/users/customers/..;/internal/v1/identity/carelog/enrollments/$ID"
want_code 403 "semicolon param" "$H/api/v1/users/customers/$ID;x"
want_code 403 "encoded slash" "$H/api/v1/users/customers%2f..%2finternal%2fv1"
want_code 403 "PUT enrollment via encoded internal (%69)" -X PUT "$H/api/v1/%69nternal/v1/identity/carelog/enrollments/$ID"
want_code 403 "backslash" "$H/api/v1/users/customers\\..\\internal"
want_code 403 "root" "$H/"
want_code 403 "actuator on app port" "$H/actuator/health"
want_code 403 "rag route" "$H/rag/anything"
want_code 403 "auth route (Core owns it)" -X POST "$H/api/v1/auth/login"
want_code 403 "OPTIONS customers (method not in list)" -X OPTIONS "$H/api/v1/users/customers"
want_code 403 "OPTIONS enrollment on 8080" -X OPTIONS "$H$ENR"
want_code 403 "uppercase prefix (regex is case-sensitive)" "$H/API/V1/users/customers"
want_code 403 "trailing slash on collection" "$H/api/v1/users/customers/"
want_code 403 "double slash prefix (merge_slashes off)" "$H//api/v1/users/customers"
want_code 403 "double slash enrollment on 8443" $TLS -X PUT "https://carelog.test:8443//api/v1/internal/v1/identity/carelog/enrollments/$ID"
want_code 403 "encoded id segment with slash (%2F)" "$H/api/v1/users/customers/a%2Fb"
want_code 403 "claims with trailing dot-segment" "$H/api/v1/internal/identity/claims/$ID/."
want_code 403 "healthz on task IP 8080 is not routed" "$H/healthz"

echo "== 8443 enrollment only (TLS, matching CA and hostname)"
reaches_backend "PUT enrollment" $TLS -X PUT "$S$ENR"
want_code 403 "GET enrollment" $TLS "$S$ENR"
want_code 403 "PUT customers on 8443" $TLS -X PUT "$S/api/v1/users/customers"
want_code 403 "PUT enrollment with ;" $TLS -X PUT "$S$ENR;x"
want_code 403 "PUT enrollment dot-dot" $TLS -X PUT "$S$ENR/../../../users/customers"
want_code 403 "PUT claims on 8443" $TLS -X PUT "$S/api/v1/internal/identity/claims/$ID"
want_code 403 "HEAD enrollment on 8443" $TLS -I "$S$ENR"
want_code 403 "OPTIONS enrollment on 8443" $TLS -X OPTIONS "$S$ENR"
want_code 403 "PATCH enrollment on 8443" $TLS -X PATCH "$S$ENR"
want_code 403 "root on 8443" $TLS "$S/"
want_code 403 "healthz on task IP 8443 is not routed" $TLS "$S/healthz"
# Enrollment body limit is 4 KB: 4000 bytes reaches the backend, 5000 bytes is refused by nginx with 413.
head -c 4000 /dev/zero | tr '\0' a >/tmp/body-4000
head -c 5000 /dev/zero | tr '\0' a >/tmp/body-5000
reaches_backend "PUT enrollment, 4000-byte body" $TLS -X PUT --data-binary @/tmp/body-4000 "$S$ENR"
want_code 413 "PUT enrollment, 5000-byte body" $TLS -X PUT --data-binary @/tmp/body-5000 "$S$ENR"
if curl -sS --noproxy '*' --resolve wrong.test:8443:127.0.0.2 --cacert /tmp/ca.crt https://wrong.test:8443/ >/dev/null 2>&1; then
  echo "FAIL wrong hostname accepted"; fail=1
else echo "ok   wrong hostname rejected"; fi
if curl -sS --noproxy '*' --resolve carelog.test:8443:127.0.0.2 https://carelog.test:8443/ >/dev/null 2>&1; then
  echo "FAIL untrusted CA accepted"; fail=1
else echo "ok   untrusted CA rejected"; fi

echo "== health route (loopback only) and ECS healthCheck command"
# The exact command from task-fragments.json / carelog.tfvars.example / Dockerfile HEALTHCHECK, unescaped.
cat >/tmp/healthcheck.sh <<'HEALTHEOF'
kill -0 $(cat /run/nginx.pid) && IP=$(grep -o 'listen [0-9.]*:8080' /etc/nginx/conf.d/default.conf | head -n 1 | cut -d' ' -f2 | cut -d: -f1) && nc -z $IP 8080 && nc -z $IP 8443 && nc -z 127.0.0.1 8080 && S=$(openssl s_client -connect $IP:8443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2) && F=$(openssl x509 -in /run/carelog-tls/server.crt -noout -fingerprint -sha256 | cut -d= -f2) && [ -n "$S" ] && [ "$S" = "$F" ] && wget -q -T 3 -O /dev/null http://127.0.0.1:9180/healthz
HEALTHEOF
HC=$(cat /tmp/healthcheck.sh)
# health: runs the ECS command under sh -c, as ECS does for CMD-SHELL. Returns 0 when healthy.
health() { sh -c "$HC" >/dev/null 2>&1; }
# expect_health <0|1> <label>
expect_health() {
  want=$1; label=$2
  if health; then got=0; else got=1; fi
  if [ "$got" = "$want" ]; then printf 'ok   healthCheck %s -> exit %s\n' "$label" "$got"
  else printf 'FAIL healthCheck %s -> exit %s (want %s)\n' "$label" "$got" "$want"; fail=1; fi
}
expect_health 0 "healthy (both task-IP listeners, app 8080, served cert == file cert, liveness via 9180)"
want_code 200 "loopback health route answers" http://127.0.0.1:9180/healthz
want_code 404 "loopback health server: other path" http://127.0.0.1:9180/other
want_code 000 "loopback health port not on the task IP" http://127.0.0.2:9180/healthz
if grep -q 'listen 127.0.0.1:9180;' /etc/nginx/conf.d/default.conf && [ "$(grep -c 'listen .*:9180' /etc/nginx/conf.d/default.conf)" = "1" ]; then
  echo "ok   9180 listens only on 127.0.0.1"
else echo "FAIL 9180 listen address"; fail=1; fi

cp /etc/nginx/conf.d/default.conf /tmp/default.conf.good
cp /run/carelog-tls/server.crt /tmp/server.crt.good
# Master process alive, 8443 listener closed (config without it, reloaded).
sed 's/listen 127.0.0.2:8443 ssl;/listen 127.0.0.2:18443 ssl;/' /tmp/default.conf.good >/etc/nginx/conf.d/default.conf
nginx -s reload; sleep 1
expect_health 1 "8443 listener closed, nginx master up"
cp /tmp/default.conf.good /etc/nginx/conf.d/default.conf; nginx -s reload; sleep 1
expect_health 0 "8443 listener restored"
# 8080 task-IP listener closed while 8443 stays up.
sed 's/listen 127.0.0.2:8080;/listen 127.0.0.2:18080;/' /tmp/default.conf.good >/etc/nginx/conf.d/default.conf
nginx -s reload; sleep 1
expect_health 1 "8080 task-IP listener closed"
cp /tmp/default.conf.good /etc/nginx/conf.d/default.conf; nginx -s reload; sleep 1
expect_health 0 "8080 task-IP listener restored"
# Wrong certificate: the file on disk changes (rotation) but nginx still serves the old one.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout /tmp/other.key -out /tmp/other.crt -subj /CN=other >/dev/null 2>&1
cp /tmp/other.crt /run/carelog-tls/server.crt
expect_health 1 "served certificate differs from the certificate file"
cp /tmp/server.crt.good /run/carelog-tls/server.crt
expect_health 0 "certificate file restored"
# Application cannot be reached: app port 8080 (TCP) and management liveness (HTTP) each fail the check.
kill "$APP_PID"; sleep 1
expect_health 1 "application 127.0.0.1:8080 stopped"
busybox-extras httpd -f -p 127.0.0.1:8080 -h /tmp/backend & APP_PID=$!; sleep 1
expect_health 0 "application 127.0.0.1:8080 restarted"
kill "$MGMT_PID"; sleep 1
expect_health 1 "management liveness unreachable (health route 502)"
busybox-extras httpd -f -p 127.0.0.1:8081 -h /tmp/mgmt & MGMT_PID=$!; sleep 1
expect_health 0 "management liveness restarted"

if [ "$fail" -eq 0 ]; then printf 'PASS: 8080 allowlist, 8443 enrollment-only, method, encoding, TLS and healthCheck checks\n'
else printf 'FAIL: see lines above\n'; exit 1; fi
