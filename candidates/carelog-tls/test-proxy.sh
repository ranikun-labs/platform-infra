#!/bin/sh
set -eu
apk add --no-cache openssl busybox-extras >/dev/null
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
code() { curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' "$@"; }
# Stub returns 404 for nonexistent backend paths: confirms routing without implementing the API.
[ "$(code http://127.0.0.2:8080/api/v1/users/customers)" = 404 ]
[ "$(code http://127.0.0.2:8080/api/v1/customer-events)" = 404 ]
[ "$(code http://127.0.0.2:8080/api/v1/internal/identity/claims)" = 404 ]
[ "$(code http://127.0.0.2:8080/api/v1/internal/v1/identity/carelog/enrollments/a)" = 403 ]
[ "$(code --path-as-is http://127.0.0.2:8080/api/v1/users/customers/../../internal/v1/identity/carelog/enrollments/a)" = 403 ]
[ "$(code --path-as-is http://127.0.0.2:8080/api/v1/%69nternal/v1/identity/carelog/enrollments/a)" = 403 ]
[ "$(code --resolve carelog.test:8443:127.0.0.2 --cacert /tmp/ca.crt https://carelog.test:8443/api/v1/internal/v1/identity/carelog/enrollments/a)" = 404 ]
[ "$(code --resolve carelog.test:8443:127.0.0.2 --cacert /tmp/ca.crt https://carelog.test:8443/api/v1/users/customers)" = 403 ]
if curl -sS --noproxy '*' --resolve wrong.test:8443:127.0.0.2 --cacert /tmp/ca.crt https://wrong.test:8443/ >/dev/null 2>&1; then exit 1; fi
if curl -sS --noproxy '*' --resolve carelog.test:8443:127.0.0.2 https://carelog.test:8443/ >/dev/null 2>&1; then exit 1; fi
printf 'PASS: stub routing, denied paths, TLS trust and hostname checks\n'
