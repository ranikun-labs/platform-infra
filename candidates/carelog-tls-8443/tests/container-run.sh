#!/bin/sh
# Runs inside the carelog-tls-proxy image (CI only). Installs test-only tools (JDK, iproute2, python3, git) and runs the
# full host-mode suite against the mounted workspace. Nothing here is part of the image.
# Usage (CI): docker run --rm --entrypoint sh -v "$GITHUB_WORKSPACE:/work" <proxy image> /work/candidates/carelog-tls-8443/tests/container-run.sh
set -eu
apk add --no-cache git coreutils iproute2 python3 openjdk17-jdk >/dev/null
git config --global --add safe.directory /work
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
cd /work/candidates/carelog-tls-8443
sh tests/run-all.sh /tmp/carelog-tls-run
