#!/bin/sh
# Self-managed DEV CA tests, host mode. Covers ca/make-root.sh, ca/issue-leaf.sh, trust-init on the public root, and JDK
# HttpClient behaviour against a local TLS server for each leaf. Name constraints are exercised by leaves that the
# script itself would refuse (signed with openssl directly, same root key), so the JDK is the enforcement point under test.
# Usage: test-selfca.sh <workdir>   (needs openssl, jq, keytool, a JDK 17, python3, and a writable /etc/hosts)
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:?usage: test-selfca.sh <workdir>}
NS=test.internal
SVC=carelog-dev.test.internal
OTHER=other.test.internal
OUTSIDE=evil.example.org
LOOP=127.0.0.2
PORT=9443
JH=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}
export JAVA_HOME="$JH"
TAG=selfca-$$
SELF=$WORK/selfca
PASSES=0
FAILS=0
EVID=$WORK/selfca-evidence.txt
mkdir -p "$SELF"
: > "$EVID"
SRV_PID=""

log() { echo "$*" | tee -a "$EVID"; }
ok() { PASSES=$((PASSES + 1)); log "PASS [$1]"; }
bad() { FAILS=$((FAILS + 1)); log "FAIL [$1] $2"; }

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true
  sed -i "/# $TAG\$/d" /etc/hosts 2>/dev/null || true
}
trap cleanup EXIT INT TERM

expect_fail_script() {  # name env-assignments... (expects non-zero exit and no output file)
  name=$1; shift
  if env "$@" >"$SELF/last.out" 2>&1; then bad "$name" "script succeeded, refusal expected"
  else ok "$name: $(grep -m1 -E 'make-root:|issue-leaf:' "$SELF/last.out" | cut -c1-120)"; fi
}

# 1. Root CA creation (outside the repo), guards.
ROOT=$SELF/root
expect_fail_script "make-root refuses OUT_DIR inside the worktree" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR="$HERE/ca/should-not-exist" sh "$HERE/ca/make-root.sh"
[ ! -e "$HERE/ca/should-not-exist" ] && ok "no directory created inside the worktree" || bad "worktree dir created" ""
expect_fail_script "make-root refuses SERVICE_HOST outside NAMESPACE" \
  NAMESPACE=$NS SERVICE_HOST=carelog-dev.example.org OUT_DIR="$SELF/bad-root" sh "$HERE/ca/make-root.sh"
NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR=$ROOT sh "$HERE/ca/make-root.sh" > "$SELF/root.out" 2>&1 \
  && ok "make-root creates root in an operator directory" || bad "make-root" "$(tail -2 "$SELF/root.out")"
expect_fail_script "make-root refuses a non-empty OUT_DIR" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR=$ROOT sh "$HERE/ca/make-root.sh"

RC_TEXT=$(openssl x509 -in "$ROOT/root.crt" -noout -text)
echo "$RC_TEXT" | grep -q 'CA:TRUE, pathlen:0' && ok "root basicConstraints CA:TRUE pathlen:0" || bad "root basicConstraints" ""
echo "$RC_TEXT" | grep -A1 'Key Usage' | grep -q 'Certificate Sign, CRL Sign' && ok "root keyUsage keyCertSign,cRLSign" || bad "root keyUsage" ""
echo "$RC_TEXT" | grep -A6 'Name Constraints' | grep -q "DNS:.$NS" && echo "$RC_TEXT" | grep -A6 'Name Constraints' | grep -q "DNS:$SVC" \
  && ok "root nameConstraints permit .$NS and $SVC" || bad "root nameConstraints permitted" ""
echo "$RC_TEXT" | grep -A8 'Name Constraints' | grep -q 'IP:0.0.0.0/0.0.0.0' && ok "root nameConstraints exclude IPv4" || bad "root exclude IPv4" ""
span=$(( ($(date -d "$(openssl x509 -in "$ROOT/root.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date -d "$(openssl x509 -in "$ROOT/root.crt" -noout -startdate | cut -d= -f2)" +%s)) / 86400 ))
[ "$span" -ge 729 ] && [ "$span" -le 731 ] && ok "root validity ~730 days ($span)" || bad "root validity" "$span days"
[ "$(stat -c %a "$ROOT/root.key")" = 600 ] && ok "root.key mode 600" || bad "root.key mode" "$(stat -c %a "$ROOT/root.key")"
cmp -s "$ROOT/root.crt" "$ROOT/ca-bundle.pem" && ok "ca-bundle.pem is the public root only" || bad "ca-bundle.pem" ""
grep -q 'PRIVATE KEY' "$ROOT/ca-bundle.pem" && bad "ca-bundle.pem contains a key" "" || ok "ca-bundle.pem holds no private key"

# 2. Leaf issuance via the script.
LEAF=$SELF/leaf-svc
expect_fail_script "issue-leaf refuses a host outside the constraints" \
  CA_DIR=$ROOT HOST=$OUTSIDE OUT_DIR=$SELF/leaf-out sh "$HERE/ca/issue-leaf.sh"
expect_fail_script "issue-leaf refuses OUT_DIR inside the worktree" \
  CA_DIR=$ROOT HOST=$SVC OUT_DIR="$HERE/ca/should-not-exist" sh "$HERE/ca/issue-leaf.sh"
CA_DIR=$ROOT HOST=$SVC OUT_DIR=$LEAF sh "$HERE/ca/issue-leaf.sh" > "$SELF/leaf.out" 2>&1 \
  && ok "issue-leaf issues the service leaf" || bad "issue-leaf" "$(tail -2 "$SELF/leaf.out")"
CA_DIR=$ROOT HOST=$OTHER OUT_DIR=$SELF/leaf-other sh "$HERE/ca/issue-leaf.sh" >/dev/null 2>&1 \
  && ok "issue-leaf issues a sibling leaf inside the namespace (for the JDK case below)" || bad "sibling leaf" ""
expect_fail_script "issue-leaf refuses reuse of an existing leaf directory" \
  CA_DIR=$ROOT HOST=$SVC OUT_DIR=$LEAF sh "$HERE/ca/issue-leaf.sh"

LT=$(openssl x509 -in "$LEAF/leaf.crt" -noout -text)
echo "$LT" | grep -q 'CA:FALSE' && ok "leaf CA:FALSE" || bad "leaf CA:FALSE" ""
echo "$LT" | grep -q 'TLS Web Server Authentication' && ok "leaf EKU serverAuth" || bad "leaf EKU" ""
openssl x509 -in "$LEAF/leaf.crt" -noout -ext subjectAltName | grep -q "DNS:$SVC$" && ok "leaf SAN is exactly DNS:$SVC" || bad "leaf SAN" ""
span=$(( ($(date -d "$(openssl x509 -in "$LEAF/leaf.crt" -noout -enddate | cut -d= -f2)" +%s) - $(date -d "$(openssl x509 -in "$LEAF/leaf.crt" -noout -startdate | cut -d= -f2)" +%s)) / 86400 ))
[ "$span" -ge 89 ] && [ "$span" -le 91 ] && ok "leaf validity ~90 days ($span)" || bad "leaf validity" "$span days"
openssl verify -CAfile "$ROOT/root.crt" "$LEAF/leaf.crt" >/dev/null 2>&1 && ok "leaf verifies against root" || bad "leaf verify" ""
jq -e '(keys | sort) == ["tls_certificate","tls_private_key"]' "$LEAF/bundle.json" >/dev/null && ok "bundle.json has exactly the two Secrets Manager fields" || bad "bundle keys" ""
jq -j '.tls_certificate' "$LEAF/bundle.json" | cmp -s - "$LEAF/leaf.crt" && ok "bundle certificate equals leaf.crt" || bad "bundle cert" ""
[ "$(stat -c %a "$LEAF/bundle.json")" = 600 ] && [ "$(stat -c %a "$LEAF/leaf.key")" = 600 ] && ok "leaf key and bundle mode 600" || bad "leaf modes" ""

# Leaves signed by the same root with openssl directly (bypassing the script's guard) for the JDK cases.
raw_leaf() {  # name san-line subject-cn
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SELF/$1.key" 2>/dev/null
  openssl req -new -key "$SELF/$1.key" -subj "/CN=$3" -out "$SELF/$1.csr" 2>/dev/null
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "subjectAltName=$2" > "$SELF/$1.ext"
  openssl x509 -req -in "$SELF/$1.csr" -CA "$ROOT/root.crt" -CAkey "$ROOT/root.key" -set_serial 0x$(openssl rand -hex 8) \
    -days 90 -sha256 -extfile "$SELF/$1.ext" -out "$SELF/$1.crt" 2>/dev/null
}
raw_leaf outside "DNS:$OUTSIDE" "$OUTSIDE"
raw_leaf ipleaf "IP:$LOOP" "$LOOP"

# 3. trust-init on the public root only.
mkdir -p "$SELF/trust"
CARELOG_CA_BUNDLE=$ROOT/ca-bundle.pem CARELOG_TRUST_DIR=$SELF/trust JAVA_HOME=$JH \
  sh "$HERE/trust-init/trust-init.sh" > "$SELF/trust.out" 2>&1 \
  && ok "trust-init accepts the constrained root: $(tail -1 "$SELF/trust.out")" || bad "trust-init on root" "$(tail -1 "$SELF/trust.out")"
TS=$SELF/trust/cacerts

# 4. JDK behaviour per leaf. /etc/hosts maps the test names to the loopback test address; one TLS server at a time.
if ! echo "$LOOP $SVC $OTHER $OUTSIDE # $TAG" >> /etc/hosts 2>/dev/null; then
  log "SKIP JDK cases: /etc/hosts not writable"
  log "SUMMARY selfca pass=$PASSES fail=$FAILS"; [ "$FAILS" -eq 0 ]; exit $?
fi

serve() {  # cert key host
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null && wait "$SRV_PID" 2>/dev/null
  python3 -I "$HERE/tests/tls-serve.py" "$1" "$2" "$LOOP" "$PORT" > "$SELF/server.log" 2>&1 &
  SRV_PID=$!
  i=0; until python3 -c "import socket,sys; socket.create_connection(('$LOOP',$PORT),0.2).close()" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 40 ] && return 1; sleep 0.25
  done
}

jcase() {  # name want-exit url truststore(-|path) [expect-regex-in-output]
  name=$1; want=$2; url=$3; trust=$4; rx=${5:-}
  out=$(env -u JAVA_TOOL_OPTIONS "$JH/bin/java" "$HERE/tests/TlsClient.java" GET "$url" "$trust" 200 2>&1); rc=$?
  first=$(printf '%s' "$out" | head -1 | cut -c1-160)
  if [ "$rc" -eq "$want" ] && { [ -z "$rx" ] || printf '%s' "$out" | grep -qiE "$rx"; }; then
    ok "java: $name -> rc=$rc $first"
  else
    bad "java: $name" "rc=$rc want=$want $first"
  fi
}

serve "$LEAF/leaf.crt" "$LEAF/leaf.key" || { bad "server start (service leaf)" "$(cat "$SELF/server.log")"; }
jcase "service leaf accepted for its SAN host" 0 "https://$SVC:$PORT/" "$TS"
jcase "service leaf refused by default JDK truststore" 2 "https://$SVC:$PORT/" "-"

serve "$SELF/leaf-other/leaf.crt" "$SELF/leaf-other/leaf.key" || bad "server start (sibling leaf)" "$(cat "$SELF/server.log")"
jcase "sibling leaf in namespace presented for $SVC refused (hostname)" 2 "https://$SVC:$PORT/" "$TS"
jcase "sibling leaf in namespace accepted for its own name (nameConstraints allow the namespace)" 0 "https://$OTHER:$PORT/" "$TS"

serve "$SELF/outside.crt" "$SELF/outside.key" || bad "server start (outside leaf)" "$(cat "$SELF/server.log")"

serve "$SELF/ipleaf.crt" "$SELF/ipleaf.key" || bad "server start (ip leaf)" "$(cat "$SELF/server.log")"

# FINDING cases: documented observed behaviour, not a control. They fail the suite only if the JDK changes.
finding() {  # name want-exit url truststore
  name=$1; want=$2; url=$3; trust=$4
  out=$(env -u JAVA_TOOL_OPTIONS "$JH/bin/java" "$HERE/tests/TlsClient.java" GET "$url" "$trust" 200 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then
    ok "FINDING [$name] observed rc=$rc (as recorded)"
  else
    bad "FINDING [$name] changed" "rc=$rc recorded=$want $(printf '%s' "$out" | head -1 | cut -c1-120)"
  fi
}

# Two-tier chain: root (trust anchor, same constraints) -> issuing CA (constrained, pathlen 0) -> leaf. The server sends
# leaf + issuing CA; only the root is in the truststore. Java checks name constraints on the intermediate it is given.
NC_TIER="critical,permitted;DNS:.$NS,permitted;DNS:$SVC,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SELF/inter.key" 2>/dev/null
openssl req -new -key "$SELF/inter.key" -subj "/CN=carelog-dev-issuing-ca" -out "$SELF/inter.csr" 2>/dev/null
printf '%s\n' "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" \
  "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "nameConstraints=$NC_TIER" > "$SELF/inter.ext"
openssl x509 -req -in "$SELF/inter.csr" -CA "$ROOT/root.crt" -CAkey "$ROOT/root.key" -set_serial 0x$(openssl rand -hex 8) \
  -days 365 -sha256 -extfile "$SELF/inter.ext" -out "$SELF/inter.crt" 2>/dev/null
openssl x509 -in "$SELF/inter.crt" -noout -ext nameConstraints >/dev/null 2>&1 && ok "issuing CA carries nameConstraints" || bad "issuing CA nameConstraints" ""
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SELF/t2-outside.key" 2>/dev/null
openssl req -new -key "$SELF/t2-outside.key" -subj "/CN=$OUTSIDE" -out "$SELF/t2-outside.csr" 2>/dev/null
printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" "extendedKeyUsage=serverAuth" \
  "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "subjectAltName=DNS:$OUTSIDE" > "$SELF/t2-outside.ext"
openssl x509 -req -in "$SELF/t2-outside.csr" -CA "$SELF/inter.crt" -CAkey "$SELF/inter.key" -set_serial 0x$(openssl rand -hex 8) \
  -days 90 -sha256 -extfile "$SELF/t2-outside.ext" -out "$SELF/t2-outside.crt" 2>/dev/null
cat "$SELF/t2-outside.crt" "$SELF/inter.crt" > "$SELF/t2-outside-chain.crt"
serve "$SELF/t2-outside-chain.crt" "$SELF/t2-outside.key" || bad "server start (two-tier outside)" "$(cat "$SELF/server.log")"
jcase "two-tier: $OUTSIDE leaf via constrained issuing CA refused" 2 "https://$OUTSIDE:$PORT/" "$TS" "constraint|PKIX|path"

openssl x509 -req -in "$SELF/t2-outside.csr" -CA "$SELF/inter.crt" -CAkey "$SELF/inter.key" -set_serial 0x$(openssl rand -hex 8) \
  -days 90 -sha256 -extfile "$SELF/t2-outside.ext" -out "$SELF/t2-outside.crt" 2>/dev/null >/dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SELF/t2-svc.key" 2>/dev/null
openssl req -new -key "$SELF/t2-svc.key" -subj "/CN=$SVC" -out "$SELF/t2-svc.csr" 2>/dev/null
printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" "extendedKeyUsage=serverAuth" \
  "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "subjectAltName=DNS:$SVC" > "$SELF/t2-svc.ext"
openssl x509 -req -in "$SELF/t2-svc.csr" -CA "$SELF/inter.crt" -CAkey "$SELF/inter.key" -set_serial 0x$(openssl rand -hex 8) \
  -days 90 -sha256 -extfile "$SELF/t2-svc.ext" -out "$SELF/t2-svc.crt" 2>/dev/null
cat "$SELF/t2-svc.crt" "$SELF/inter.crt" > "$SELF/t2-svc-chain.crt"
serve "$SELF/t2-svc-chain.crt" "$SELF/t2-svc.key" || bad "server start (two-tier svc)" "$(cat "$SELF/server.log")"
jcase "two-tier: service leaf via issuing CA accepted for $SVC" 0 "https://$SVC:$PORT/" "$TS"

# Anchor-only findings (recorded, not a control): the constrained root as trust anchor issuing the leaf directly.
serve "$SELF/outside.crt" "$SELF/outside.key" || bad "server start (finding outside)" "$(cat "$SELF/server.log")"
finding "anchor-direct: $OUTSIDE leaf accepted (nameConstraints on trust anchor not applied)" 0 "https://$OUTSIDE:$PORT/" "$TS"
serve "$SELF/ipleaf.crt" "$SELF/ipleaf.key" || bad "server start (finding ip)" "$(cat "$SELF/server.log")"
finding "anchor-direct: IP-SAN leaf accepted (excluded IP not applied)" 0 "https://$LOOP:$PORT/" "$TS"

[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

log ""
log "SUMMARY selfca pass=$PASSES fail=$FAILS"
[ "$FAILS" -eq 0 ]
