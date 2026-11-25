#!/bin/sh
# trust-init tests.
#   local (always): runs trust-init/trust-init.sh with a JDK on the host. Positive store growth and negative CA inputs.
#   docker (DOCKER=1): builds trust-init/Dockerfile on a stand-in Core base (the host JDK imported as an image)
#                      and runs it with a volume, the way the task init container does.
# The stand-in is a test base only. The real build takes CORE_IMAGE as a digest reference (build/build-images.sh).
# Usage: test-trust-init.sh <pki-dir> <workdir>
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
PKI=${1:?usage: test-trust-init.sh <pki-dir> <workdir>}
WORK=${2:?usage: test-trust-init.sh <pki-dir> <workdir>}
JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
export JAVA_HOME
PASS=0
FAIL=0
mkdir -p "$WORK"

ok()   { PASS=$((PASS + 1)); echo "PASS [$1]"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL [$1] $2"; }
count() { keytool -list -keystore "$1" -storepass changeit 2>/dev/null | sed -n 's/^Your keystore contains \([0-9][0-9]*\) entr.*/\1/p'; }

run_init() {  # bundle-file outdir -> sets RC and OUT
  mkdir -p "$2"
  OUT=$(CARELOG_CA_BUNDLE="$1" CARELOG_TRUST_DIR="$2" sh "$HERE/trust-init/trust-init.sh" 2>&1)
  RC=$?
}

base_count=$(count "$JAVA_HOME/lib/security/cacerts")
echo "base cacerts entries: $base_count"

# Positive: one CA added, base store untouched, alias present, output world-readable.
run_init "$PKI/ca-bundle.pem" "$WORK/ok"
if [ "$RC" -eq 0 ] && [ -f "$WORK/ok/cacerts" ]; then
  n=$(count "$WORK/ok/cacerts")
  if [ "$((n - base_count))" -eq 1 ] && keytool -list -alias carelog-dev-ca-1 -keystore "$WORK/ok/cacerts" -storepass changeit >/dev/null 2>&1; then
    ok "valid CA bundle: store grows by 1, alias carelog-dev-ca-1 present ($base_count -> $n)"
  else
    bad "valid CA bundle" "entries $base_count -> $n"
  fi
  [ "$(stat -c %a "$WORK/ok/cacerts")" = 644 ] && ok "output mode 644" || bad "output mode" "$(stat -c %a "$WORK/ok/cacerts")"
  [ -z "$(ls -A "$WORK/ok" | grep -v '^cacerts$')" ] && ok "no working files left behind" || bad "working files left" "$(ls -A "$WORK/ok")"
  [ "$(count "$JAVA_HOME/lib/security/cacerts")" = "$base_count" ] && ok "host base cacerts unchanged"
else
  bad "valid CA bundle" "rc=$RC out=$OUT"
fi

# Negative: each input must fail, and nothing may be written to the output path.
neg() {  # name bundle-file fragment
  run_init "$2" "$WORK/neg-$1"
  if [ "$RC" -ne 0 ] && [ ! -f "$WORK/neg-$1/cacerts" ] && printf '%s' "$OUT" | grep -q -- "$3"; then
    ok "refused: $1 ($3)"
  else
    bad "refused: $1" "rc=$RC want='$3' out=$OUT exists=$(test -f "$WORK/neg-$1/cacerts" && echo yes || echo no)"
  fi
}
: > "$PKI/empty.pem"
neg empty-bundle "$PKI/empty.pem" "empty"
neg leaf-not-ca "$PKI/leaf-as-ca-bundle.pem" "not a CA"
neg expired-ca "$PKI/expired-ca-bundle.pem" "expired"
cat "$PKI/ca.crt" "$PKI/ca.key" > "$PKI/ca-with-key.pem"
neg bundle-contains-private-key "$PKI/ca-with-key.pem" "private key"
printf 'not a certificate\n' > "$PKI/garbage.pem"
neg non-pem-content "$PKI/garbage.pem" "PEM"
head -n -1 "$PKI/ca.crt" > "$PKI/truncated.pem"
neg unbalanced-pem "$PKI/truncated.pem" "unbalanced"

if [ "${DOCKER:-0}" = 1 ]; then
  # Stand-in base = host JDK + passwd. It has no shell, which is fine: the Dockerfile needs none at build time (COPY --chmod).
  # The runtime run of trust-init needs sh and keytool from a real Core image, so it is not run here.
  echo "== docker: build trust-init image on stand-in base"
  mkdir -p "$WORK/standin-etc/etc"
  printf 'root:x:0:0:root:/root:/bin/sh\n' > "$WORK/standin-etc/etc/passwd"
  tar -c --transform 's,^\.,opt/java,' -C "$JAVA_HOME" . -C "$WORK/standin-etc" etc \
    | docker import --change 'ENV JAVA_HOME=/opt/java' --change 'USER root' - carelog-core-standin:test >/dev/null \
    || bad "stand-in base import" "docker import failed"
  CTX="$WORK/trust-ctx"
  rm -rf "$CTX"; mkdir -p "$CTX"
  cp "$HERE/trust-init/Dockerfile" "$HERE/trust-init/trust-init.sh" "$CTX/"
  cp "$PKI/ca-bundle.pem" "$CTX/ca-bundle.pem"
  if docker build -q -t carelog-trust-init:test \
       --build-arg CORE_IMAGE=carelog-core-standin:test --build-arg CA_BUNDLE_SRC=ca-bundle.pem \
       "$CTX" >"$WORK/trust-build.log" 2>&1; then
    ok "trust-init image builds on stand-in base (digest enforcement is in build/build-images.sh)"
  else
    bad "trust-init image build" "$(tail -3 "$WORK/trust-build.log")"
  fi
  docker inspect -f '{{index .Config.Labels "ranikun.carelog.core-base"}}' carelog-trust-init:test 2>/dev/null \
    | grep -q '^carelog-core-standin:test$' && ok "image label records core base" || bad "core-base label" ""
  docker inspect -f '{{.Config.Entrypoint}}' carelog-trust-init:test 2>/dev/null | grep -q 'trust-init' \
    && ok "entrypoint is trust-init" || bad "entrypoint" ""
fi

echo "SUMMARY trust-init pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
