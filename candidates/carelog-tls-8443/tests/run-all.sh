#!/bin/sh
# Runs every local test. Host mode needs nginx, openssl, jq, wget, curl, ss, keytool and a JDK 17 on the host.
# Usage: tests/run-all.sh [workdir]   DOCKER=1 also builds the trust-init image on a stand-in base.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-$(mktemp -d)}
mkdir -p "$WORK"
sh "$HERE/tests/gen-material.sh" "$WORK/pki"
sh "$HERE/tests/test-entrypoint-negative.sh" "$WORK" "$WORK/pki"
sh "$HERE/tests/test-trust-init.sh" "$WORK/pki" "$WORK/trust"
sh "$HERE/tests/test-proxy-host.sh" "$WORK"
sh "$HERE/tests/test-selfca.sh" "$WORK/selfca-run"
echo "all suites passed; evidence: $WORK/evidence.txt, $WORK/selfca-run/selfca-evidence.txt"
