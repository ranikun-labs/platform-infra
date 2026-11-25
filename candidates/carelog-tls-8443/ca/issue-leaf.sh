#!/bin/sh
# Issues the 90-day server leaf for Core enrollment/claims, signed by the issuing CA. Run on the issuing host.
#   CA_DIR   directory from make-root.sh (root.crt, issuing.crt, issuing.key, constraints.env)
#   HOST     the name Core dials; must equal TLS_EXPECTED_DNS_SAN and fall under the constraints
#   OUT_DIR  operator-chosen directory OUTSIDE the git worktree (created 0700, one per issuance)
# Writes:
#   leaf.crt      leaf certificate (CA:FALSE, EKU serverAuth, SAN DNS:HOST, 90 days)
#   leaf.key      leaf private key, 0600. Generated here, never leaves OUT_DIR.
#   bundle.json   Secrets Manager string, mode 0600:
#                 {"tls_certificate": "<leaf PEM><issuing CA PEM>", "tls_private_key": "<leaf key PEM>"}
#                 The chain is leaf first, then the issuing CA. No CA key is ever in the bundle.
# The chain is verified against root.crt (with the issuing CA as untrusted intermediate and HOST checked) before writing.
set -eu
umask 077
fail() { echo "issue-leaf: $1" >&2; exit 1; }

CA_DIR=${CA_DIR:?CA_DIR required}
HOST=${HOST:?HOST required}
OUT_DIR=${OUT_DIR:?OUT_DIR required (outside the repo)}
DAYS=${DAYS:-90}

for f in root.crt issuing.crt issuing.key constraints.env; do
  [ -f "$CA_DIR/$f" ] || fail "CA_DIR has no $f"
done
. "$CA_DIR/constraints.env"

mode=$(stat -c %a "$CA_DIR/issuing.key" 2>/dev/null || stat -f %Lp "$CA_DIR/issuing.key")
case "$mode" in 600|400) ;; *) fail "issuing.key mode is $mode; expected 600" ;; esac

case "$HOST" in *[!a-z0-9.-]*|'') fail "HOST is not a plain lower-case DNS name" ;; esac
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
openssl x509 -req -in "$OUT_DIR/leaf.csr" -CA "$CA_DIR/issuing.crt" -CAkey "$CA_DIR/issuing.key" \
  -set_serial "0x$(openssl rand -hex 16)" -days "$DAYS" -sha256 -extfile "$ext" -out "$OUT_DIR/leaf.crt" 2>/dev/null \
  || fail "signing failed"
rm -f "$OUT_DIR/leaf.csr" "$ext"

# Verify the full chain to the root, with the name constraints of the issuing CA applied, and the SAN host.
openssl verify -CAfile "$CA_DIR/root.crt" -untrusted "$CA_DIR/issuing.crt" -verify_hostname "$HOST" \
  "$OUT_DIR/leaf.crt" >/dev/null 2>&1 || fail "leaf does not verify to root.crt through issuing.crt"

cat "$OUT_DIR/leaf.crt" "$CA_DIR/issuing.crt" > "$OUT_DIR/chain.pem"
jq -n --rawfile c "$OUT_DIR/chain.pem" --rawfile k "$OUT_DIR/leaf.key" \
  '{tls_certificate: $c, tls_private_key: $k}' > "$OUT_DIR/bundle.json"
rm -f "$OUT_DIR/chain.pem"
chmod 600 "$OUT_DIR/bundle.json"

echo "issue-leaf: leaf for $HOST issued into $OUT_DIR (chain: leaf + issuing CA)"
openssl x509 -in "$OUT_DIR/leaf.crt" -noout -subject -enddate
cat <<MSG
issue-leaf: next steps (operator)
  1. Store bundle.json as a new version of the bundle secret (from this host, with an operator principal):
       aws secretsmanager put-secret-value --secret-id <bundle secret ARN> --secret-string file://$OUT_DIR/bundle.json
  2. Force a new proxy deployment so the entrypoint reads the new version.
  3. Shred OUT_DIR/leaf.key and bundle.json after the put succeeds. The secret now holds the leaf key.
MSG
