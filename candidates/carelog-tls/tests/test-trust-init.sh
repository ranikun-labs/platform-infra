#!/bin/sh
# shellcheck disable=SC2015 # pass/fail helpers never fail; A && pass || fail is intentional here
# trust-init: baked bundle, 2-CA bundle, store growth, Core aliases preserved, and negative bundles.
# Usage: test-trust-init.sh <trust-image (built from the Core digest, CA baked: 1 CA)> <core-image> <material-dir>
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"
TRUST="$1"; CORE="$2"; M="$3"
W=$(make_work trust); trap 'rm -rf "$W"; docker volume rm -f carelog-tls-t-$$-a carelog-tls-t-$$-b carelog-tls-t-$$-c >/dev/null 2>&1' EXIT INT TERM
VA=carelog-tls-t-$$-a; VB=carelog-tls-t-$$-b; VC=carelog-tls-t-$$-c

# Aliases of the Core image's own store (the baseline that must survive).
base_aliases=$(docker run --rm --entrypoint sh "$CORE" -c 'keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | sort')
base_count=$(echo "$base_aliases" | grep -c . || true)
[ "$base_count" -gt 100 ] && pass "Core base store has $base_count trusted entries" || fail "Core base store unexpectedly small ($base_count)"

# run_init <volume> <image> <bundle-host-file-or-empty> : prints trust-init output, returns its exit code.
run_init() {
  vol=$1; img=$2; bundle=$3
  if [ -n "$bundle" ]; then
    docker run --rm -v "$vol:/run/carelog-trust" -v "$(host_path "$bundle"):/ca/bundle.pem:ro" \
      -e CARELOG_CA_BUNDLE=/ca/bundle.pem "$img" 2>&1
  else
    docker run --rm -v "$vol:/run/carelog-trust" "$img" 2>&1
  fi
}

# 1. Baked bundle (1 CA): exactly one more entry than the base.
docker volume rm -f "$VA" >/dev/null 2>&1
out=$(run_init "$VA" "$TRUST" ""); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "imported 1 CA certificate(s); store entries $base_count -> $((base_count + 1))"; then pass "baked CA: store $base_count -> $((base_count + 1)), exit 0"
else fail "baked CA: store growth" "rc=$rc $(echo "$out" | tail -1)"; fi

# 2. Aliases: every base alias still present, plus the carelog alias.
got=$(docker run --rm -v "$VA:/run/carelog-trust" --entrypoint sh "$CORE" -c 'keytool -list -keystore /run/carelog-trust/cacerts -storepass changeit 2>/dev/null | grep trustedCertEntry | cut -d, -f1 | sort')
echo "$base_aliases" > "$W/base.txt"; echo "$got" > "$W/got.txt"; missing=$(grep -vxFf "$W/got.txt" "$W/base.txt" | grep -c . || true)
[ "$missing" -eq 0 ] && pass "all $base_count Core CA aliases still present after init" || fail "Core CA aliases missing after init" "$missing missing"
echo "$got" | grep -q '^carelog-dev-ca-1$' && pass "carelog-dev-ca-1 alias present" || fail "carelog-dev-ca-1 alias missing"

# 3. Two-CA bundle (rotation overlap): store grows by exactly 2.
docker volume rm -f "$VB" >/dev/null 2>&1
out=$(run_init "$VB" "$TRUST" "$M/ca-bundle-2.pem"); rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "imported 2 CA certificate(s); store entries $base_count -> $((base_count + 2))"; then pass "2-CA bundle: store $base_count -> $((base_count + 2))"
else fail "2-CA bundle: store growth" "rc=$rc $(echo "$out" | tail -1)"; fi

# 4. Negative bundles: each must exit non-zero, name the check, and leave no cacerts behind.
neg() { # label bundle expected-substring
  docker volume rm -f "$VC" >/dev/null 2>&1
  out=$(run_init "$VC" "$TRUST" "$M/$2"); rc=$?
  has=$(docker run --rm -v "$VC:/run/carelog-trust" --entrypoint sh "$TRUST" -c 'test -e /run/carelog-trust/cacerts && echo yes || echo no')
  if [ $rc -ne 0 ] && echo "$out" | grep -q -- "$3" && [ "$has" = no ]; then pass "$1"
  else fail "$1" "rc=$rc want='$3' output-store=$has $(echo "$out" | tail -1)"; fi
}
neg "empty bundle refused" ca-bundle-empty.pem "empty"
neg "non-PEM text refused" ca-bundle-text.pem "no PEM certificate"
neg "PEM with a stray text line refused" ca-bundle-nonpem.pem "non-PEM content"
neg "bundle containing a private key refused" ca-bundle-key.pem "private key"
neg "leaf (non-CA) certificate refused" ca-bundle-leaf.pem "not a CA"
neg "expired CA refused" ca-bundle-expired.pem "expired"

# 5. Missing bundle path refused.
docker volume rm -f "$VC" >/dev/null 2>&1
out=$(docker run --rm -v "$VC:/run/carelog-trust" -e CARELOG_CA_BUNDLE=/nope.pem "$TRUST" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'not readable' && pass "missing bundle path refused" || fail "missing bundle path refused" "rc=$rc"

summary test-trust-init
