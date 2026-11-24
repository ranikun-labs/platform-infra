#!/bin/sh
# Fails unless the trust-init image is built FROM exactly the expected Core image digest.
#
# Usage:
#   check-core-digest.sh <trust-image> <expected-core-ref>
#   check-core-digest.sh --tfvars <platform.tfvars.example> <trust-image>
#   check-core-digest.sh --taskdef <rendered-core-task-definition.json> <pushed-trust-init-ref> [local-trust-image]
#
# The expected Core digest is the Core container image of the candidate Core task definition:
#   - positional mode: given explicitly (the workflow passes the candidate Core input);
#   - --tfvars mode: read from enrollment_core_candidate.image in the platform input file, and that
#     image must equal enrollment_core_candidate.trust_init_core_base.
# Also fails when the expected reference is not a digest reference, or is not the pinned candidate
# digest (PINNED_CORE_DIGEST) when CHECK_PINNED=1 (the workflow sets it).
#
# Independent checks on the trust-init image:
#   1. label ranikun.carelog.core-base equals the expected reference (set from the CORE_IMAGE build arg);
#   2. the layer list starts with the expected Core image's layer list (the image really sits on that base).
set -eu

PINNED_CORE_DIGEST="124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core@sha256:8353cec4aa9bee820f43fa36e5a387f02c7873e1c680f825bf33c179dab182bf"
fail() { echo "check-core-digest: FAIL $1" >&2; exit 1; }

if [ "${1:-}" = "--taskdef" ]; then
  # Deploy-time mode: the ACTUAL rendered Core task definition JSON (the one to be registered) and the ACTUAL
  # pushed trust-init reference. Checks: the application image is the pinned candidate digest and equals the
  # trust-init base label (and layers) of the local trust-init image; the init container image equals the pushed
  # digest, is digest-pinned, mounts carelog-trust writable at /run/carelog-trust; the application container
  # depends on the init container (SUCCESS) and mounts carelog-trust read-only. Messages name keys only.
  TD="${2:?task definition JSON file required}"; PUSHED="${3:?pushed trust-init reference required}"
  LOCAL_TRUST="${4:-$PUSHED}"
  [ -r "$TD" ] || fail "task definition file not readable"
  # jq from the host, or from the proxy image when the host has none (no secret is passed to jq).
  jq_() { if command -v jq >/dev/null 2>&1; then jq "$@"; else docker run --rm -i --entrypoint jq "${JQ_IMAGE:-carelog-tls-proxy:tests}" "$@"; fi; }
  case "$PUSHED" in
    *@sha256:????????????????????????????????????????????????????????????????) ;;
    *) fail "pushed trust-init reference is not a digest reference" ;;
  esac
  n_app=$(jq_ -r '[.containerDefinitions[] | select(.name != "carelog-trust-init")] | length' < "$TD") || fail "task definition is not readable JSON"
  n_init=$(jq_ -r '[.containerDefinitions[] | select(.name == "carelog-trust-init")] | length' < "$TD")
  [ "$n_app" = 1 ] || fail "task definition must have exactly one application container (found $n_app)"
  [ "$n_init" = 1 ] || fail "task definition must have exactly one carelog-trust-init container (found $n_init)"
  APP_IMG=$(jq_ -r '[.containerDefinitions[] | select(.name != "carelog-trust-init")][0].image' < "$TD")
  INIT_IMG=$(jq_ -r '[.containerDefinitions[] | select(.name == "carelog-trust-init")][0].image' < "$TD")

  [ "$APP_IMG" = "$PINNED_CORE_DIGEST" ] || fail "application container image is not the pinned candidate Core digest (8353cec4)"
  jq_ -e '[.volumes[]? | select(.name == "carelog-trust")] | length == 1' < "$TD" >/dev/null || fail "carelog-trust volume is not declared"
  [ "$INIT_IMG" = "$PUSHED" ] || fail "trust-init container image differs from the pushed trust-init reference"
  case "$INIT_IMG" in
    *@sha256:????????????????????????????????????????????????????????????????) ;;
    *) fail "trust-init container image is not digest-pinned" ;;
  esac
  jq_ -e '[.containerDefinitions[] | select(.name == "carelog-trust-init") | (.mountPoints // [])[]
          | select(.sourceVolume == "carelog-trust" and .containerPath == "/run/carelog-trust" and .readOnly == false)] | length == 1' \
    < "$TD" >/dev/null || fail "trust-init container must mount carelog-trust at /run/carelog-trust writable (readOnly false)"
  jq_ -e '[.containerDefinitions[] | select(.name != "carelog-trust-init") | (.mountPoints // [])[]
          | select(.sourceVolume == "carelog-trust" and .containerPath == "/run/carelog-trust" and .readOnly == true)] | length == 1' \
    < "$TD" >/dev/null || fail "application container must mount carelog-trust at /run/carelog-trust read-only"
  jq_ -e '[.containerDefinitions[] | select(.name != "carelog-trust-init") | (.dependsOn // [])[]
          | select(.containerName == "carelog-trust-init" and .condition == "SUCCESS")] | length == 1' \
    < "$TD" >/dev/null || fail "application container must depend on carelog-trust-init with condition SUCCESS"
  # Base label and layers of the local trust-init image against the application image (same checks as positional mode).
  # Invoked through sh: the file is not executable in git (100644), so "$0" alone cannot re-run it.
  sh "$0" "$LOCAL_TRUST" "$APP_IMG" >/dev/null 2>&1 || fail "trust-init image base (label or layers) does not match the application image"
  echo "check-core-digest: PASS rendered task definition matches the pinned Core digest, the pushed trust-init digest and its wiring"
  exit 0
fi

if [ "${1:-}" = "--print-candidate" ]; then
  # Prints the candidate Core image from the platform input (used by the workflow pre-build check).
  PRINT_FILE="${2:?tfvars file required}"
  awk '/^enrollment_core_candidate = \{/{f=1; next} f && /^\}/{exit} f{print}' "$PRINT_FILE" \
    | awk -F'"' '/^[ \t]*image[ \t]*=/{print $2; exit}'
  exit 0
fi

if [ "${1:-}" = "--tfvars" ]; then
  TFVARS="${2:?tfvars file required}"; TRUST="${3:?trust image required}"
  [ -r "$TFVARS" ] || fail "tfvars file not readable"
  # Values of image and trust_init_core_base inside the enrollment_core_candidate block.
  block=$(awk '/^enrollment_core_candidate = \{/{f=1; next} f && /^\}/{exit} f{print}' "$TFVARS")
  [ -n "$block" ] || fail "enrollment_core_candidate block not found in $TFVARS"
  EXPECTED=$(printf '%s\n' "$block" | awk -F'"' '/^[ \t]*image[ \t]*=/{print $2; exit}')
  BASE=$(printf '%s\n' "$block" | awk -F'"' '/trust_init_core_base[ \t]*=/{print $2; exit}')
  [ -n "$EXPECTED" ] || fail "candidate Core image not found in $TFVARS"
  [ "$BASE" = "$EXPECTED" ] || fail "trust_init_core_base differs from the candidate Core image in $TFVARS"
  TRUST_ARG="$TRUST"
else
  TRUST_ARG="${1:?trust image required}"; EXPECTED="${2:?expected Core reference required}"
fi

case "$EXPECTED" in
  *@sha256:????????????????????????????????????????????????????????????????) ;;
  *) fail "expected Core reference is not a digest reference" ;;
esac
if [ "${CHECK_PINNED:-0}" = 1 ] && [ "$EXPECTED" != "$PINNED_CORE_DIGEST" ]; then
  fail "candidate Core image is not the pinned enrollment-capable digest (8353cec4...)"
fi

label=$(docker image inspect "$TRUST_ARG" --format '{{index .Config.Labels "ranikun.carelog.core-base"}}' 2>/dev/null) \
  || fail "trust image not found: $TRUST_ARG"
[ "$label" = "$EXPECTED" ] || fail "label ranikun.carelog.core-base does not match the expected Core digest"

docker image inspect "$EXPECTED" >/dev/null 2>&1 || fail "expected Core image is not available locally (pull it first)"
core_layers=$(docker image inspect "$EXPECTED" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
trust_layers=$(docker image inspect "$TRUST_ARG" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
n=$(echo "$core_layers" | grep -c . || true)
[ "$n" -gt 0 ] || fail "no layers in expected Core image"
prefix=$(echo "$trust_layers" | head -n "$n")
[ "$prefix" = "$core_layers" ] || fail "trust image layers do not start with the expected Core image layers"

echo "check-core-digest: PASS trust-init base equals the expected Core digest"
