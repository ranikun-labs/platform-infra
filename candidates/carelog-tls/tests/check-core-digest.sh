#!/bin/sh
# Fails unless the trust-init image is built FROM exactly the expected Core image digest.
# Two independent checks: (1) the image label ranikun.carelog.core-base equals the expected reference
# (the label is set from the CORE_IMAGE build arg); (2) the trust image's layer list starts with the
# expected Core image's layer list (the image really sits on that base).
# Usage: check-core-digest.sh <trust-image> <expected-core-ref>
# The expected ref must be the Core image digest used by the Core task definition (repo@sha256:...).
set -eu
TRUST="$1"; EXPECTED="$2"
fail() { echo "check-core-digest: FAIL $1" >&2; exit 1; }

case "$EXPECTED" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) fail "expected Core reference is not a digest reference" ;;
esac

label=$(docker image inspect "$TRUST" --format '{{index .Config.Labels "ranikun.carelog.core-base"}}' 2>/dev/null) \
  || fail "trust image not found: $TRUST"
[ "$label" = "$EXPECTED" ] || fail "label ranikun.carelog.core-base does not match the expected Core digest"

docker image inspect "$EXPECTED" >/dev/null 2>&1 || fail "expected Core image is not available locally (pull it first)"
core_layers=$(docker image inspect "$EXPECTED" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
trust_layers=$(docker image inspect "$TRUST" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
n=$(echo "$core_layers" | grep -c . || true)
[ "$n" -gt 0 ] || fail "no layers in expected Core image"
prefix=$(echo "$trust_layers" | head -n "$n")
[ "$prefix" = "$core_layers" ] || fail "trust image layers do not start with the expected Core image layers"

echo "check-core-digest: PASS trust-init base equals the expected Core digest"
