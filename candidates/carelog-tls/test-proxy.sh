#!/bin/sh
# Local-only routing test for nginx.conf. A busybox httpd stub stands in for Carelog on 127.0.0.1:8080.
# The stub returns 404 for every path, so "reached the backend" is observed as 404, and nginx's own
# refusal is observed as 403. No real credentials or AWS resources are involved.
set -eu
apk add --no-cache openssl curl busybox-extras >/dev/null
mkdir -p /run/carelog-tls /tmp/backend
printf 'stub-ok\n' >/tmp/backend/index.html
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout /tmp/ca.key -out /tmp/ca.crt -subj /CN=test-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout /run/carelog-tls/server.key -out /tmp/server.csr -subj /CN=carelog.test >/dev/null 2>&1
printf 'subjectAltName=DNS:carelog.test\n' >/tmp/ext.cnf
openssl x509 -req -in /tmp/server.csr -CA /tmp/ca.crt -CAkey /tmp/ca.key -CAcreateserial -days 1 -extfile /tmp/ext.cnf -out /run/carelog-tls/server.crt >/dev/null 2>&1
TASK_IPV4=127.0.0.2 envsubst '${TASK_IPV4}' </etc/nginx/templates/carelog.conf >/etc/nginx/conf.d/default.conf
nginx -t
busybox-extras httpd -p 127.0.0.1:8080 -h /tmp/backend
nginx
# ECS container healthCheck in task-fragments.json / carelog.tfvars.example runs exactly this on the proxy container.
kill -0 "$(cat /run/nginx.pid)" && echo "ok   healthCheck kill -0 nginx pid"
head -c 4000 /dev/zero | tr '\0' a >/tmp/body-4000
head -c 5000 /dev/zero | tr '\0' a >/tmp/body-5000

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

echo "== 8080 allowed (Gateway routes, Core claims, health)"
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
want_code 404 "GET health" "$H/api/v1/health"
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
# Enrollment body limit is 4 KB: 4000 bytes reaches the backend, 5000 bytes is refused by nginx with 413.
reaches_backend "PUT enrollment, 4000-byte body" $TLS -X PUT --data-binary @/tmp/body-4000 "$S$ENR"
want_code 413 "PUT enrollment, 5000-byte body" $TLS -X PUT --data-binary @/tmp/body-5000 "$S$ENR"
if curl -sS --noproxy '*' --resolve wrong.test:8443:127.0.0.2 --cacert /tmp/ca.crt https://wrong.test:8443/ >/dev/null 2>&1; then
  echo "FAIL wrong hostname accepted"; fail=1
else echo "ok   wrong hostname rejected"; fi
if curl -sS --noproxy '*' --resolve carelog.test:8443:127.0.0.2 https://carelog.test:8443/ >/dev/null 2>&1; then
  echo "FAIL untrusted CA accepted"; fail=1
else echo "ok   untrusted CA rejected"; fi

if [ "$fail" -eq 0 ]; then printf 'PASS: 8080 allowlist, 8443 enrollment-only, method, encoding and TLS checks\n'
else printf 'FAIL: see lines above\n'; exit 1; fi
