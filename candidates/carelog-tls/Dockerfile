# Carelog DEV TLS proxy sidecar. Base is pinned by digest (nginx:1.27-alpine, resolved 2026-11-24).
# Master process runs as root only to write the task volume and bind the task IP;
# nginx workers run as the unprivileged `nginx` user (stock /etc/nginx/nginx.conf).
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
ARG SOURCE_SHA=unknown
LABEL org.opencontainers.image.revision=$SOURCE_SHA \
      org.opencontainers.image.title="carelog-tls-proxy"
# openssl is used only by the entrypoint to compare certificate and key public keys (fail-fast pair check).
RUN apk add --no-cache jq=1.8.2-r0 openssl=3.3.7-r2
COPY nginx.conf /etc/nginx/templates/carelog.conf
COPY proxy-entrypoint.sh /usr/local/bin/carelog-proxy
RUN chmod 755 /usr/local/bin/carelog-proxy \
 && chmod 644 /etc/nginx/templates/carelog.conf \
 && mkdir -p /run/carelog-tls && chmod 700 /run/carelog-tls
# ECS ignores Dockerfile HEALTHCHECK; the task definition carries the same command (task-fragments.json,
# carelog.tfvars.example). start-period 300s: the app took 161-179 s to start in DEV logs (2026-11-21).
# Failures during start-period do not count, so the proxy is not killed while the app is starting.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 CMD ["/bin/sh", "-c", "kill -0 $(cat /run/nginx.pid) && IP=$(grep -o 'listen [0-9.]*:8080' /etc/nginx/conf.d/default.conf | head -n 1 | cut -d' ' -f2 | cut -d: -f1) && nc -z $IP 8080 && nc -z $IP 8443 && nc -z 127.0.0.1 8080 && S=$(openssl s_client -connect $IP:8443 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2) && F=$(openssl x509 -in /run/carelog-tls/server.crt -noout -fingerprint -sha256 | cut -d= -f2) && [ -n \"$S\" ] && [ \"$S\" = \"$F\" ] && wget -q -T 3 -O /dev/null http://127.0.0.1:9180/healthz"]
ENTRYPOINT ["/usr/local/bin/carelog-proxy"]
