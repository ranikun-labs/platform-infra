#!/bin/sh
# Core / trust-init base digest checks.
# Usage: test-core-digest.sh <trust-cand> <core-cand> <trust-live> <core-live> <platform.tfvars.example>
#   trust-cand / core-cand: trust-init built FROM the enrollment-capable candidate Core (8353cec4).
#   trust-live / core-live: trust-init built FROM the live Core (ad9f8428), used as the negative reference.
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"
TRUST_CAND="$1"; CORE_CAND="$2"; TRUST_LIVE="$3"; CORE_LIVE="$4"; TFVARS="$5"
W=$(make_work digest)
trap 'rm -rf "$W"; docker rmi -f carelog-tls-forged-label >/dev/null 2>&1' EXIT INT TERM
CHK="$TESTS_DIR/check-core-digest.sh"

if sh "$CHK" "$TRUST_CAND" "$CORE_CAND" >/dev/null 2>&1; then pass "candidate trust-init matches the candidate Core digest"
else fail "candidate trust-init matches the candidate Core digest"; fi

if CHECK_PINNED=1 sh "$CHK" --tfvars "$TFVARS" "$TRUST_CAND" >/dev/null 2>&1; then pass "tfvars example: candidate Core input equals trust-init base and the pinned digest"
else fail "tfvars example: candidate Core input equals trust-init base and the pinned digest"; fi

if CHECK_PINNED=1 sh "$CHK" --tfvars "$TFVARS" "$TRUST_LIVE" >/dev/null 2>&1; then fail "trust-init built from the live Core must fail against the candidate input"
else pass "trust-init built from the live Core (ad9f8428) fails against the candidate input"; fi

if sh "$CHK" "$TRUST_CAND" "$CORE_LIVE" >/dev/null 2>&1; then fail "label check must fail when the expected Core digest differs"
else pass "label mismatch (candidate trust-init, live Core expected) fails"; fi

if sh "$CHK" "$TRUST_LIVE" "$CORE_CAND" >/dev/null 2>&1; then fail "trust-init built from the live Core must fail against the candidate Core"
else pass "trust-init built from the live Core fails against the candidate Core"; fi

if CHECK_PINNED=1 sh "$CHK" "$TRUST_LIVE" "$CORE_LIVE" >/dev/null 2>&1; then fail "pinned check must refuse a non-pinned Core digest"
else pass "pinned check refuses the live digest as candidate"; fi

# Forged label: an image on the LIVE base whose label claims the candidate digest. Only the layers can catch it.
printf 'FROM %s\nLABEL ranikun.carelog.core-base="%s"\n' "$TRUST_LIVE" "$CORE_CAND" > "$W/Dockerfile"
if docker build -q -f "$(host_path "$W/Dockerfile")" -t carelog-tls-forged-label "$(host_path "$W")" >/dev/null 2>&1; then
  if sh "$CHK" carelog-tls-forged-label "$CORE_CAND" >/dev/null 2>&1; then fail "forged label on the live base must fail the layer check"
  else pass "forged label on the live base fails the layer check"; fi
else fail "could not build the forged-label fixture"; fi

if sh "$CHK" "$TRUST_CAND" "$CORE_CAND-tampered" >/dev/null 2>&1; then fail "non-digest reference must be refused"
else pass "non-digest expected reference refused"; fi

summary test-core-digest
