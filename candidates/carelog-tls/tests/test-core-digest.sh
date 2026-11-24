#!/bin/sh
# Core/trust-init base digest match: positive case and negative cases (label or layers differ).
# Usage: test-core-digest.sh <trust-image-live-base> <core-live-ref> <trust-image-old-base> <core-old-ref>
. "$(dirname "$0")/lib.sh"
TRUST_LIVE="$1"; CORE_LIVE="$2"; TRUST_OLD="$3"; CORE_OLD="$4"
W=$(make_work digest); trap 'rm -rf "$W"; docker rmi -f carelog-tls-forged-label >/dev/null 2>&1' EXIT INT TERM

if sh "$TESTS_DIR/check-core-digest.sh" "$TRUST_LIVE" "$CORE_LIVE" >/dev/null 2>&1; then pass "live trust image matches the live Core digest"
else fail "live trust image matches the live Core digest"; fi

if sh "$TESTS_DIR/check-core-digest.sh" "$TRUST_LIVE" "$CORE_OLD" >/dev/null 2>&1; then fail "label check must fail when the Core digest differs"
else pass "label mismatch (trust built from live Core, expected older Core) fails"; fi

if sh "$TESTS_DIR/check-core-digest.sh" "$TRUST_OLD" "$CORE_LIVE" >/dev/null 2>&1; then fail "must fail when the trust image is built from an older Core"
else pass "trust image built from an older Core digest fails against the live Core digest"; fi

# Forged label: an image on the OLDER base whose label claims the live digest. Only the layer check can catch it.
printf 'FROM %s\nLABEL ranikun.carelog.core-base="%s"\n' "$TRUST_OLD" "$CORE_LIVE" > "$W/Dockerfile"
if docker build -q -f "$(host_path "$W/Dockerfile")" -t carelog-tls-forged-label "$(host_path "$W")" >/dev/null 2>&1; then
  if sh "$TESTS_DIR/check-core-digest.sh" carelog-tls-forged-label "$CORE_LIVE" >/dev/null 2>&1; then fail "forged label on an older base must fail the layer check"
  else pass "forged label on an older base fails the layer check"; fi
else fail "could not build the forged-label fixture"; fi

if sh "$TESTS_DIR/check-core-digest.sh" "$TRUST_LIVE" "$CORE_LIVE-tampered" >/dev/null 2>&1; then fail "non-digest reference must be refused"
else pass "non-digest expected reference refused"; fi

summary test-core-digest
