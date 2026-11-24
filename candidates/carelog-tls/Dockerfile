# Carelog DEV TLS proxy sidecar. Base is pinned by digest (nginx:1.27-alpine, resolved 2026-11-24).
# Master process runs as root only to write the task volume and bind the task IP;
# nginx workers run as the unprivileged `nginx` user (stock /etc/nginx/nginx.conf).
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
ARG SOURCE_SHA=unknown
LABEL org.opencontainers.image.revision=$SOURCE_SHA \
      org.opencontainers.image.title="carelog-tls-proxy"
RUN apk add --no-cache jq=1.8.2-r0
COPY nginx.conf /etc/nginx/templates/carelog.conf
COPY proxy-entrypoint.sh /usr/local/bin/carelog-proxy
RUN chmod 755 /usr/local/bin/carelog-proxy \
 && chmod 644 /etc/nginx/templates/carelog.conf \
 && mkdir -p /run/carelog-tls && chmod 700 /run/carelog-tls
# ECS ignores Dockerfile HEALTHCHECK; the task definition must set an equivalent container healthCheck.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 CMD ["/bin/sh", "-c", "kill -0 \"$(cat /run/nginx.pid)\""]
ENTRYPOINT ["/usr/local/bin/carelog-proxy"]
