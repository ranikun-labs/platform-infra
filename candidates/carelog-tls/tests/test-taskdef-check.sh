#!/bin/sh
# Deploy-time check of the rendered Core task definition (check-core-digest.sh --taskdef).
# Usage: test-taskdef-check.sh <trust-candidate-image (base 8353cec4)> <trust-live-image (base ad9f8428)>
# Fixtures (no secrets): tests/fixtures/core-taskdef-*.json. Pushed trust-init reference used by the fixtures:
#   124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccc...cc
. "$(dirname "$0")/lib.sh"
TRUST_CAND="$1"; TRUST_LIVE="$2"
PUSHED="124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
CHK="$TESTS_DIR/check-core-digest.sh"
FX="$TESTS_DIR/fixtures"

# expect <pass|fail> <label> <message-substring or -> <taskdef-file> <pushed-ref> <local-trust-image>
expect() {
  want=$1; label=$2; sub=$3; td=$4; pushed=$5; local_trust=$6
  out=$(sh "$CHK" --taskdef "$td" "$pushed" "$local_trust" 2>&1); rc=$?
  if [ "$want" = pass ]; then
    if [ "$rc" -eq 0 ]; then pass "$label"; else fail "$label" "$(echo "$out" | tail -1)"; fi
  else
    if [ "$rc" -ne 0 ] && { [ "$sub" = - ] || echo "$out" | grep -q -- "$sub"; }; then pass "$label"
    else fail "$label" "rc=$rc want='$sub' $(echo "$out" | tail -1)"; fi
  fi
}

expect pass "good rendered task definition passes (pinned app image, pushed init digest, wiring)" - "$FX/core-taskdef-good.json" "$PUSHED" "$TRUST_CAND"
expect fail "application image not the pinned candidate digest" "pinned candidate Core digest" "$FX/core-taskdef-bad-app-image.json" "$PUSHED" "$TRUST_CAND"
expect fail "init image given as a tag, not the pushed digest" "differs from the pushed" "$FX/core-taskdef-init-tag.json" "$PUSHED" "$TRUST_CAND"
expect fail "init image digest differs from the pushed digest" "differs from the pushed" "$FX/core-taskdef-init-digest-mismatch.json" "$PUSHED" "$TRUST_CAND"
expect fail "init container without its own carelog-trust mount" "writable" "$FX/core-taskdef-init-no-mount.json" "$PUSHED" "$TRUST_CAND"
expect fail "init container mount read-only" "writable" "$FX/core-taskdef-init-readonly.json" "$PUSHED" "$TRUST_CAND"
expect fail "application container without dependsOn SUCCESS" "depend" "$FX/core-taskdef-no-depends-on.json" "$PUSHED" "$TRUST_CAND"
expect fail "application container mount not read-only" "read-only" "$FX/core-taskdef-app-no-ro-mount.json" "$PUSHED" "$TRUST_CAND"
expect fail "carelog-trust volume not declared" "volume" "$FX/core-taskdef-no-volume.json" "$PUSHED" "$TRUST_CAND"
expect fail "two application containers" "exactly one application" "$FX/core-taskdef-two-app-containers.json" "$PUSHED" "$TRUST_CAND"
expect fail "pushed reference differs from the rendered init image" "differs from the pushed" "$FX/core-taskdef-good.json" "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" "$TRUST_CAND"
expect fail "pushed reference is a tag" "not a digest reference" "$FX/core-taskdef-good.json" "124495093425.dkr.ecr.ap-northeast-2.amazonaws.com/ranikun/platform/core-trust-init:latest" "$TRUST_CAND"
expect fail "trust-init image built on the live base (label differs from the 8353 application image)" "base (label or layers)" "$FX/core-taskdef-good.json" "$PUSHED" "$TRUST_LIVE"

summary test-taskdef-check
