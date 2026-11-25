# syntax=docker/dockerfile:1
# Carelog DEV trust-init image: builds the per-task truststore for Core.
# FROM ${CORE_IMAGE}: the SAME Core image digest that the Core task definition runs (repo@sha256:...).
#   build/build-images.sh rejects anything that is not a digest reference.
# CA_BUNDLE_SRC: PUBLIC PEM bundle of Carelog DEV CA certificates (CA:TRUE only). Never a key, never a secret.
# Output: /run/carelog-trust/cacerts = Core base cacerts + the bundle certificates (store is copied, never replaced).
# Modes and owners are set by COPY --chmod, so the build needs no shell in the base image.
# hadolint global ignore=DL3002,DL3066
ARG CORE_IMAGE
FROM ${CORE_IMAGE}
ARG CORE_IMAGE
ARG SOURCE_SHA=unknown
ARG CA_BUNDLE_SRC
LABEL org.opencontainers.image.revision=$SOURCE_SHA \
      org.opencontainers.image.title="carelog-trust-init" \
      ranikun.carelog.core-base="${CORE_IMAGE}"
COPY --chmod=0644 ${CA_BUNDLE_SRC} /usr/local/share/carelog/carelog-dev-ca-bundle.pem
COPY --chmod=0755 trust-init.sh /usr/local/bin/trust-init
# Root is needed only to write the task volume (/run/carelog-trust). The Core base image already runs as root.
USER root
ENTRYPOINT ["/usr/local/bin/trust-init"]
