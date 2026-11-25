#!/bin/sh
# Issues the 90-day server leaf for Core enrollment/claims. Run on the operator host that holds root.key.
#   CA_DIR   directory from make-root.sh (root.crt, root.key, constraints.env)
#   HOST     the name Core dials; must equal TLS_EXPECTED_DNS_SAN and fall under the CA's constraints
#   OUT_DIR  operator-chosen directory OUTSIDE the git worktree (created 0700)
# Writes (leaf key is generated here and never leaves OUT_DIR):
#   leaf.crt        leaf certificate only (CA:FALSE, EKU serverAuth, SAN DNS:HOST, 90 days)
#   leaf.key        leaf private key, mode 0600
#   bundle.json     Secrets Manager string for ranikun/dev/carelog/enrollment-tls/server-bundle, mode 0600
#                   {"tls_certificate": "<leaf PEM>", "tls_private_key": "<key PEM>"}
# The leaf chain is verified against root.crt before anything is written. Nothing secret is printed.
set -eu
umask 077
fail() { echo "issue-leaf: $1" >&2; exit 1; }

CA_DIR=${CA_DIR:?CA_DIR required}
HOST=${HOST:?HOST required}
OUT_DIR=${OUT_DIR:?OUT_DIR required (outside the repo)}
DAYS=${DAYS:-90}

[ -f "$CA_DIR/root.key" ] || fail "CA_DIR has no root.key"
[ -f "$CA_DIR/root.crt" ] || fail "CA_DIR has no root.crt"
[ -f "$CA_DIR/constraints.env" ] || fail "CA_DIR has no constraints.env"
. "$CA_DIR/constraints.env"

# Permission check: the CA key must not be readable by others (make-root writes it 0600).
mode=$(stat -c %a "$CA_DIR/root.key" 2>/dev/null || stat -f %Lp "$CA_DIR/root.key")
case "$mode" in 600|400) ;; *) fail "root.key mode is $mode; expected 600" ;; esac

# Host must be a plain DNS name that is the service host or under the namespace. The CA's nameConstraints
# would refuse anything else at validation time; refusing here gives an earlier, clearer error.
lower=$(printf '%s' "$HOST" | tr '[:upper:]' '[:lower:]')
[ "$lower" = "$HOST" ] || fail "HOST must be lower case"
case "$HOST" in *[!a-z0-9.-]*|'') fail "HOST is not a plain DNS name" ;; esac
case "$HOST" in
  "$SERVICE_HOST") ;;
  *".$NAMESPACE") ;;
  *) fail "HOST is outside the CA constraints (namespace $NAMESPACE, service host $SERVICE_HOST)" ;;
esac

REPO=$(git -C "$(cd "$(dirname "$0")" && pwd)" rev-parse --show-toplevel 2>/dev/null || true)
case "$OUT_DIR" in /*) ;; *) fail "OUT_DIR must be an absolute path" ;; esac
if [ -n "$REPO" ]; then
  case "$OUT_DIR" in "$REPO"|"$REPO"/*) fail "OUT_DIR is inside the git worktree; choose a path outside it" ;; esac
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
[ ! -e "$OUT_DIR/leaf.key" ] || fail "OUT_DIR already holds a leaf; use a new directory per issuance"

ext="$OUT_DIR/leaf.ext"
printf '%s\n' \
  "basicConstraints=critical,CA:FALSE" \
  "keyUsage=critical,digitalSignature" \
  "extendedKeyUsage=serverAuth" \
  "subjectKeyIdentifier=hash" \
  "authorityKeyIdentifier=keyid" \
  "subjectAltName=DNS:$HOST" > "$ext"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT_DIR/leaf.key" 2>/dev/null
chmod 600 "$OUT_DIR/leaf.key"
openssl req -new -key "$OUT_DIR/leaf.key" -subj "/CN=$HOST" -out "$OUT_DIR/leaf.csr" 2>/dev/null
serial="0x$(openssl rand -hex 16)"
openssl x509 -req -in "$OUT_DIR/leaf.csr" -CA "$CA_DIR/root.crt" -CAkey "$CA_DIR/root.key" \
  -set_serial "$serial" -days "$DAYS" -sha256 -extfile "$ext" -out "$OUT_DIR/leaf.crt" 2>/dev/null \
  || fail "signing failed"
rm -f "$OUT_DIR/leaf.csr" "$ext"

# Verify the chain and the SAN before writing the bundle.
openssl verify -CAfile "$CA_DIR/root.crt" "$OUT_DIR/leaf.crt" >/dev/null 2>&1 || fail "leaf does not verify against root.crt"
openssl x509 -in "$OUT_DIR/leaf.crt" -noout -ext subjectAltName | grep -q "DNS:$HOST" || fail "SAN check failed"

jq -n --rawfile c "$OUT_DIR/leaf.crt" --rawfile k "$OUT_DIR/leaf.key" \
  '{tls_certificate: $c, tls_private_key: $k}' > "$OUT_DIR/bundle.json"
chmod 600 "$OUT_DIR/bundle.json"

echo "issue-leaf: leaf for $HOST issued into $OUT_DIR"
openssl x509 -in "$OUT_DIR/leaf.crt" -noout -subject -enddate
cat <<MSG
issue-leaf: next steps (operator)
  1. Store bundle.json as a new version of the bundle secret (AWS CLI, from this operator host):
       aws secretsmanager put-secret-value --secret-id <bundle secret ARN> --secret-string file://$OUT_DIR/bundle.json
  2. Force a new proxy deployment so the entrypoint reads the new version.
  3. Shred OUT_DIR/leaf.key and bundle.json after the put succeeds (the secret holds the key). Keep the directory out of the repo.
MSG
