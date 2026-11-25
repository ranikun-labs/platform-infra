# Carelog DEV TLS front proxy (sidecar). Base pinned by digest (nginx:1.27-alpine, resolved 2026-11-24).
# The master process runs as root only to write the task-local secret file and bind the task IP;
# nginx workers run as the unprivileged `nginx` user (stock /etc/nginx/nginx.conf).
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
ARG SOURCE_SHA=unknown
LABEL org.opencontainers.image.revision=$SOURCE_SHA \
      org.opencontainers.image.title="carelog-tls-proxy"
# jq parses TLS_BUNDLE_JSON; openssl checks the certificate, key pair and SAN before nginx starts.
RUN apk add --no-cache jq=1.8.2-r0 openssl=3.3.7-r2
COPY nginx.conf.template /etc/nginx/templates/carelog-tls.conf.template
COPY proxy-entrypoint.sh /usr/local/bin/carelog-proxy
# conf.d/default.conf is rendered by the entrypoint from the template.
RUN chmod 755 /usr/local/bin/carelog-proxy \
 && chmod 644 /etc/nginx/templates/carelog-tls.conf.template \
 && mkdir -p /run/carelog-tls && chmod 700 /run/carelog-tls
# ECS ignores the Dockerfile HEALTHCHECK; the task definition carries the same command.
# Passes when nginx is alive, the loopback health route reaches the app liveness probe, and the TLS listener is bound.
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
  CMD ["/bin/sh", "-c", "kill -0 $(cat /run/nginx.pid) && wget -q -T 3 -O /dev/null http://127.0.0.1:9180/healthz && IP=$(sed -n 's/^ *listen \\([0-9.]*\\):8443 ssl;.*/\\1/p' /etc/nginx/conf.d/default.conf | head -n 1) && nc -z \"$IP\" 8443"]
ENTRYPOINT ["/usr/local/bin/carelog-proxy"]
