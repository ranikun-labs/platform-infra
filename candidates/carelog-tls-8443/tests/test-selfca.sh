#!/bin/sh
# Self-managed two-tier DEV CA tests, host mode. Covers ca/make-root.sh, ca/issue-leaf.sh, trust-init on the public root,
# and JDK HttpClient behaviour against a local TLS server presenting leaf + issuing CA. Certificates that the scripts would
# refuse are signed with openssl directly using the issuing key, so the JDK is the enforcement point under test.
# Also measures an external https host through the JDK default truststore and through the trust-init store.
# Usage: test-selfca.sh <workdir>   (needs openssl, jq, keytool, a JDK 17, python3, a writable /etc/hosts; the external
#        part needs HTTPS_PROXY and a reachable external host, otherwise it is reported as SKIP)
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
info() { log "INFO [$1] $2"; }

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null || true
  sed -i "/# $TAG\$/d" /etc/hosts 2>/dev/null || true
}
trap cleanup EXIT INT TERM

refused_script() {  # name env-assignments... (expects non-zero exit)
  name=$1; shift
  if env "$@" >"$SELF/last.out" 2>&1; then bad "$name" "script succeeded, refusal expected"
  else ok "$name: $(grep -m1 -E 'make-root:|issue-leaf:' "$SELF/last.out" | cut -c1-120)"; fi
}
days() { echo $(( ($(date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s) - $(date -d "$(openssl x509 -in "$1" -noout -startdate | cut -d= -f2)" +%s)) / 86400 )); }

# 1. Root and issuing CA (operator directory, outside the repo).
ROOT=$SELF/root
refused_script "make-root refuses OUT_DIR inside the worktree" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR="$HERE/ca/should-not-exist" sh "$HERE/ca/make-root.sh"
[ ! -e "$HERE/ca/should-not-exist" ] && ok "no directory created inside the worktree" || bad "worktree dir created" ""
# OUT_DIR guard: '..' and symlinks are resolved before the check; a copy of the script outside git is still guarded.
refused_script "make-root refuses '..' path into the worktree" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR="$HERE/ca/../ca/traversal-check" sh "$HERE/ca/make-root.sh"
[ ! -e "$HERE/ca/traversal-check" ] && ok "no directory created via '..' path" || bad "traversal dir created" ""
ln -s "$HERE/ca" "$SELF/link-to-worktree"
refused_script "make-root refuses a symlink that resolves into the worktree" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR="$SELF/link-to-worktree/symlink-check" sh "$HERE/ca/make-root.sh"
[ ! -e "$HERE/ca/symlink-check" ] && ok "no directory created via symlink" || bad "symlink dir created" ""
mkdir -p "$SELF/copied" && cp "$HERE/ca/make-root.sh" "$HERE/ca/issue-leaf.sh" "$SELF/copied/"
refused_script "script copied outside git still refuses OUT_DIR inside the worktree" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR="$HERE/ca/should-not-exist" sh "$SELF/copied/make-root.sh"
NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR="$SELF/copied-root" sh "$SELF/copied/make-root.sh" > "$SELF/copied.out" 2>&1 \
  && ok "copied script writes an operator directory outside every repo" || bad "copied script outside repo" "$(tail -1 "$SELF/copied.out")"
refused_script "make-root refuses SERVICE_HOST outside NAMESPACE" \
  NAMESPACE=$NS SERVICE_HOST=carelog-dev.example.org OUT_DIR="$SELF/bad-root" sh "$HERE/ca/make-root.sh"
NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR=$ROOT sh "$HERE/ca/make-root.sh" > "$SELF/root.out" 2>&1 \
  && ok "make-root creates the two-tier CA in an operator directory" || bad "make-root" "$(tail -2 "$SELF/root.out")"
refused_script "make-root refuses a non-empty OUT_DIR" \
  NAMESPACE=$NS SERVICE_HOST=$SVC OUT_DIR=$ROOT sh "$HERE/ca/make-root.sh"

RT=$(openssl x509 -in "$ROOT/root.crt" -noout -text)
echo "$RT" | grep -q 'CA:TRUE, pathlen:1' && ok "root basicConstraints CA:TRUE pathlen:1" || bad "root basicConstraints" ""
echo "$RT" | grep -A6 'Name Constraints' | grep -q "DNS:.$NS" && echo "$RT" | grep -A6 'Name Constraints' | grep -q "DNS:$SVC" \
  && ok "root nameConstraints permit .$NS and $SVC" || bad "root nameConstraints permitted" ""
echo "$RT" | grep -A8 'Name Constraints' | grep -q 'IP:0.0.0.0/0.0.0.0' && ok "root nameConstraints exclude IPv4" || bad "root exclude IPv4" ""
span=$(days "$ROOT/root.crt"); [ "$span" -ge 729 ] && [ "$span" -le 731 ] && ok "root validity ~730 days ($span)" || bad "root validity" "$span"
IT=$(openssl x509 -in "$ROOT/issuing.crt" -noout -text)
echo "$IT" | grep -q 'CA:TRUE, pathlen:0' && ok "issuing CA basicConstraints CA:TRUE pathlen:0" || bad "issuing basicConstraints" ""
echo "$IT" | grep -A6 'Name Constraints' | grep -q "DNS:.$NS" && ok "issuing CA carries nameConstraints" || bad "issuing nameConstraints" ""
openssl verify -CAfile "$ROOT/root.crt" "$ROOT/issuing.crt" >/dev/null 2>&1 && ok "issuing CA verifies against root" || bad "issuing verify" ""
[ "$(stat -c %a "$ROOT/root.key")" = 600 ] && [ "$(stat -c %a "$ROOT/issuing.key")" = 600 ] && ok "root.key and issuing.key mode 600" || bad "CA key modes" ""
cmp -s "$ROOT/root.crt" "$ROOT/ca-bundle.pem" && ok "ca-bundle.pem is the root only" || bad "ca-bundle.pem" ""
[ "$(grep -c 'BEGIN CERTIFICATE' "$ROOT/ca-bundle.pem")" -eq 1 ] && ok "ca-bundle.pem holds exactly one certificate (issuing CA excluded)" || bad "ca-bundle.pem count" ""

# 2. Leaf issuance via the script (signed by the issuing CA).
LEAF=$SELF/leaf-svc
refused_script "issue-leaf refuses a host outside the constraints" CA_DIR=$ROOT HOST=$OUTSIDE OUT_DIR=$SELF/leaf-out sh "$HERE/ca/issue-leaf.sh"
mkdir -p "$SELF/badenv" && cp "$ROOT/root.crt" "$ROOT/issuing.crt" "$ROOT/issuing.key" "$SELF/badenv/"
printf 'NAMESPACE=%s\nSERVICE_HOST=%s\nEVIL=1\n' "$NS" "$SVC" > "$SELF/badenv/constraints.env"
refused_script "issue-leaf refuses constraints.env with an unexpected key" CA_DIR=$SELF/badenv HOST=$SVC OUT_DIR=$SELF/leaf-badenv1 sh "$HERE/ca/issue-leaf.sh"
printf 'NAMESPACE=%s\nSERVICE_HOST=%s\n' "$NS" '$(touch /tmp/selfca-injected)' > "$SELF/badenv/constraints.env"
refused_script "issue-leaf refuses constraints.env with a command-substitution value" CA_DIR=$SELF/badenv HOST=$SVC OUT_DIR=$SELF/leaf-badenv2 sh "$HERE/ca/issue-leaf.sh"
[ ! -e /tmp/selfca-injected ] && ok "constraints.env was not executed" || bad "constraints.env executed" ""
refused_script "issue-leaf refuses OUT_DIR inside the worktree" CA_DIR=$ROOT HOST=$SVC OUT_DIR="$HERE/ca/should-not-exist" sh "$HERE/ca/issue-leaf.sh"
CA_DIR=$ROOT HOST=$SVC OUT_DIR=$LEAF sh "$HERE/ca/issue-leaf.sh" > "$SELF/leaf.out" 2>&1 \
  && ok "issue-leaf issues the service leaf" || bad "issue-leaf" "$(tail -2 "$SELF/leaf.out")"
CA_DIR=$ROOT HOST=$OTHER OUT_DIR=$SELF/leaf-other sh "$HERE/ca/issue-leaf.sh" >/dev/null 2>&1 \
  && ok "issue-leaf issues a sibling leaf inside the namespace" || bad "sibling leaf" ""
refused_script "issue-leaf refuses reuse of an existing leaf directory" CA_DIR=$ROOT HOST=$SVC OUT_DIR=$LEAF sh "$HERE/ca/issue-leaf.sh"

LT=$(openssl x509 -in "$LEAF/leaf.crt" -noout -text)
echo "$LT" | grep -q 'CA:FALSE' && ok "leaf CA:FALSE" || bad "leaf CA:FALSE" ""
echo "$LT" | grep -q 'TLS Web Server Authentication' && ok "leaf EKU serverAuth" || bad "leaf EKU" ""
openssl x509 -in "$LEAF/leaf.crt" -noout -ext subjectAltName | grep -q "DNS:$SVC$" && ok "leaf SAN is exactly DNS:$SVC" || bad "leaf SAN" ""
span=$(days "$LEAF/leaf.crt"); [ "$span" -ge 89 ] && [ "$span" -le 91 ] && ok "leaf validity ~90 days ($span)" || bad "leaf validity" "$span"
openssl verify -CAfile "$ROOT/root.crt" -untrusted "$ROOT/issuing.crt" -verify_hostname "$SVC" "$LEAF/leaf.crt" >/dev/null 2>&1 \
  && ok "leaf verifies to root through issuing CA with SAN host" || bad "leaf chain verify" ""
jq -e '(keys | sort) == ["tls_certificate","tls_private_key"]' "$LEAF/bundle.json" >/dev/null && ok "bundle.json has exactly the two Secrets Manager fields" || bad "bundle keys" ""
jq -j '.tls_certificate' "$LEAF/bundle.json" > "$SELF/bundle-chain.pem"
[ "$(grep -c 'BEGIN CERTIFICATE' "$SELF/bundle-chain.pem")" -eq 2 ] && ok "bundle tls_certificate holds leaf + issuing CA (2 certificates)" || bad "bundle chain count" ""
cat "$LEAF/leaf.crt" "$ROOT/issuing.crt" > "$SELF/expect-chain.pem"; cmp -s "$SELF/bundle-chain.pem" "$SELF/expect-chain.pem" && ok "bundle chain equals leaf.crt then issuing.crt" || bad "bundle chain order/content" ""
jq -j '.tls_private_key' "$LEAF/bundle.json" | cmp -s - "$LEAF/leaf.key" && ok "bundle key equals leaf.key" || bad "bundle key" ""
grep -q 'PRIVATE KEY' "$SELF/bundle-chain.pem" && bad "bundle certificate field holds a key" "" || ok "bundle certificate field holds no key"
[ "$(stat -c %a "$LEAF/bundle.json")" = 600 ] && [ "$(stat -c %a "$LEAF/leaf.key")" = 600 ] && ok "leaf key and bundle mode 600" || bad "leaf modes" ""

# Raw issuance with openssl (bypasses the script's host guard), signed by the issuing CA or directly by the root.
raw_leaf() {  # name signer-crt signer-key san-line cn
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$SELF/$1.key" 2>/dev/null
  openssl req -new -key "$SELF/$1.key" -subj "/CN=$5" -out "$SELF/$1.csr" 2>/dev/null
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "subjectAltName=$4" > "$SELF/$1.ext"
  openssl x509 -req -in "$SELF/$1.csr" -CA "$2" -CAkey "$3" -set_serial 0x$(openssl rand -hex 8) \
    -days 90 -sha256 -extfile "$SELF/$1.ext" -out "$SELF/$1.crt" 2>/dev/null
  cat "$SELF/$1.crt" "$ROOT/issuing.crt" > "$SELF/$1-chain.pem"
}
raw_leaf evil-iss "$ROOT/issuing.crt" "$ROOT/issuing.key" "DNS:$OUTSIDE" "$OUTSIDE"
raw_leaf ip-iss "$ROOT/issuing.crt" "$ROOT/issuing.key" "IP:$LOOP" "$LOOP"
raw_leaf evil-root "$ROOT/root.crt" "$ROOT/root.key" "DNS:$OUTSIDE" "$OUTSIDE"
cp "$SELF/evil-root.crt" "$SELF/evil-root-chain.pem"

# 3. trust-init on the public root only.
mkdir -p "$SELF/trust"
CARELOG_CA_BUNDLE=$ROOT/ca-bundle.pem CARELOG_TRUST_DIR=$SELF/trust JAVA_HOME=$JH \
  sh "$HERE/trust-init/trust-init.sh" > "$SELF/trust.out" 2>&1 \
  && ok "trust-init imports only the root: $(tail -1 "$SELF/trust.out")" || bad "trust-init on root" "$(tail -1 "$SELF/trust.out")"
TS=$SELF/trust/cacerts

# 4. JDK behaviour per served chain. /etc/hosts maps the test names to the loopback test address; one TLS server at a time.
if ! echo "$LOOP $SVC $OTHER $OUTSIDE # $TAG" >> /etc/hosts 2>/dev/null; then
  log "SKIP JDK cases: /etc/hosts not writable"
  log "SUMMARY selfca pass=$PASSES fail=$FAILS"; [ "$FAILS" -eq 0 ]; exit $?
fi

serve() {  # chain-file key-file
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null && wait "$SRV_PID" 2>/dev/null
  python3 -I "$HERE/tests/tls-serve.py" "$1" "$2" "$LOOP" "$PORT" > "$SELF/server.log" 2>&1 &
  SRV_PID=$!
  i=0; until python3 -c "import socket; socket.create_connection(('$LOOP',$PORT),0.2).close()" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 40 ] && return 1; sleep 0.25
  done
}
jcase() {  # name want-exit url truststore(-|path)
  name=$1; want=$2; url=$3; trust=$4
  out=$(env -u JAVA_TOOL_OPTIONS "$JH/bin/java" "$HERE/tests/TlsClient.java" GET "$url" "$trust" 200 2>&1); rc=$?
  first=$(printf '%s' "$out" | grep -v '^Picked up' | head -1 | cut -c1-140)
  if [ "$rc" -eq "$want" ]; then ok "java: $name -> rc=$rc $first"; else bad "java: $name" "rc=$rc want=$want $first"; fi
}
finding() {  # name want-exit url truststore(-|path)   (records observed behaviour; fails only if it changes)
  name=$1; want=$2; url=$3; trust=$4
  out=$(env -u JAVA_TOOL_OPTIONS "$JH/bin/java" "$HERE/tests/TlsClient.java" GET "$url" "$trust" 200 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then ok "FINDING [$name] observed rc=$rc (as recorded)"; else bad "FINDING [$name] changed" "rc=$rc recorded=$want"; fi
}
keyof() { jq -r '.tls_private_key' "$1"; }

serve "$SELF/bundle-chain.pem" "$LEAF/leaf.key" || bad "server start (service chain)" "$(cat "$SELF/server.log")"
jcase "two-tier service chain accepted for its SAN host" 0 "https://$SVC:$PORT/" "$TS"
jcase "service chain refused by default JDK truststore" 2 "https://$SVC:$PORT/" "-"

jq -r '.tls_certificate' "$SELF/leaf-other/bundle.json" > "$SELF/other-chain.pem"; keyof "$SELF/leaf-other/bundle.json" > "$SELF/other.key"
serve "$SELF/other-chain.pem" "$SELF/other.key" || bad "server start (sibling chain)" "$(cat "$SELF/server.log")"
jcase "sibling in namespace presented for $SVC refused (hostname)" 2 "https://$SVC:$PORT/" "$TS"
jcase "sibling in namespace accepted for its own name" 0 "https://$OTHER:$PORT/" "$TS"

serve "$SELF/evil-iss-chain.pem" "$SELF/evil-iss.key" || bad "server start (evil via issuing)" "$(cat "$SELF/server.log")"
jcase "leaf for $OUTSIDE signed by the ISSUING CA refused (name constraints)" 2 "https://$OUTSIDE:$PORT/" "$TS"
serve "$SELF/ip-iss-chain.pem" "$SELF/ip-iss.key" || bad "server start (ip via issuing)" "$(cat "$SELF/server.log")"
jcase "IP-SAN leaf signed by the ISSUING CA refused (excluded IP)" 2 "https://$LOOP:$PORT/" "$TS"

# Anchor-only finding: a leaf issued directly by the root (not a shipped shape) is accepted.
serve "$SELF/evil-root-chain.pem" "$SELF/evil-root.key" || bad "server start (finding)" "$(cat "$SELF/server.log")"
finding "root-direct: $OUTSIDE leaf accepted (root nameConstraints not applied to a direct leaf)" 0 "https://$OUTSIDE:$PORT/" "$TS"

[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

# 5. External host: JDK default truststore vs the trust-init store, through the same CONNECT proxy.
EXT_HOST=pypi.org
EXT_URL="https://$EXT_HOST/simple/"
PROXY_HP=$(printf '%s' "${HTTPS_PROXY:-}" | sed -E 's|^[a-z]+://||; s|^[^@]*@||; s|/.*$||')
BASE_TS=$(printf '%s' "${JAVA_TOOL_OPTIONS:-}" | sed -n 's/.*-Djavax.net.ssl.trustStore=\([^ ]*\).*/\1/p')
[ -n "$BASE_TS" ] || BASE_TS=$JH/lib/security/cacerts
if [ -z "$PROXY_HP" ]; then
  info "external" "SKIP: HTTPS_PROXY not set; no external host reached"
else
  mkdir -p "$SELF/fakehome/lib/security" && cp "$BASE_TS" "$SELF/fakehome/lib/security/cacerts"
  mkdir -p "$SELF/ext-trust"
  CARELOG_CA_BUNDLE=$ROOT/ca-bundle.pem CARELOG_TRUST_DIR=$SELF/ext-trust JAVA_HOME=$SELF/fakehome \
    sh "$HERE/trust-init/trust-init.sh" > "$SELF/ext-trust.out" 2>&1 \
    && ok "derived store built from the same base as the JVM default: $(tail -1 "$SELF/ext-trust.out")" \
    || bad "derived store (external)" "$(tail -1 "$SELF/ext-trust.out")"
  def_out=$(TLSCLIENT_PROXY=$PROXY_HP "$JH/bin/java" "$HERE/tests/TlsClient.java" GET "$EXT_URL" - 200 2>&1); def_rc=$?
  der_out=$(TLSCLIENT_PROXY=$PROXY_HP "$JH/bin/java" "$HERE/tests/TlsClient.java" GET "$EXT_URL" "$SELF/ext-trust/cacerts" 200 2>&1); der_rc=$?
  info "external default" "rc=$def_rc $(printf '%s' "$def_out" | grep -v '^Picked up' | head -1 | cut -c1-120)"
  info "external derived" "rc=$der_rc $(printf '%s' "$der_out" | grep -v '^Picked up' | head -1 | cut -c1-120)"
  if [ "$def_rc" -eq "$der_rc" ]; then ok "external host $EXT_HOST: derived store result equals JDK default (rc=$def_rc)"
  else bad "external host $EXT_HOST: derived store differs from default" "default=$def_rc derived=$der_rc"; fi
fi

log ""
log "SUMMARY selfca pass=$PASSES fail=$FAILS"
[ "$FAILS" -eq 0 ]
