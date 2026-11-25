#!/bin/sh
# Creates the self-managed Carelog DEV two-tier CA. Run on an offline operator host, never in CI or in a task.
#   root.crt      pathlen:1, nameConstraints. Trust anchor; only this certificate goes into trust-init (ca-bundle.pem).
#   issuing.crt   pathlen:0, the same nameConstraints. Signs the server leaves. Sent in the leaf chain (not trusted by Core).
#   NAMESPACE     DNS namespace the CA may sign for, e.g. dev.carelog.internal
#   SERVICE_HOST  the exact name Core dials, e.g. carelog-dev.dev.carelog.internal
#   OUT_DIR       operator-chosen directory OUTSIDE this git worktree. Created 0700. Must not already hold files.
# Writes:
#   root.key        root private key, 0600. Needed only to sign a new issuing CA. Keep offline.
#   issuing.key     issuing CA private key, 0600. Needed for every leaf issuance. Keep on the issuing host only.
#   root.crt, issuing.crt, ca-bundle.pem (= root.crt), constraints.env (public)
# Algorithm: ECDSA P-256. Validity: root 730 days, issuing CA 365 days (ISSUING_DAYS), leaves 90 days (issue-leaf.sh).
set -eu
umask 077
fail() { echo "make-root: $1" >&2; exit 1; }

NAMESPACE=${NAMESPACE:?NAMESPACE required, e.g. dev.carelog.internal}
SERVICE_HOST=${SERVICE_HOST:?SERVICE_HOST required, e.g. carelog-dev.dev.carelog.internal}
OUT_DIR=${OUT_DIR:?OUT_DIR required (outside the repo)}
ROOT_DAYS=${ROOT_DAYS:-730}
ISSUING_DAYS=${ISSUING_DAYS:-365}

plain_dns() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
plain_dns "$NAMESPACE" || fail "NAMESPACE must be a lower-case DNS name with at least two labels"
plain_dns "$SERVICE_HOST" || fail "SERVICE_HOST must be a lower-case DNS name"
case "$SERVICE_HOST" in *".$NAMESPACE") ;; *) fail "SERVICE_HOST must end with .$NAMESPACE" ;; esac

# The CA keys must never land inside a git worktree.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)
case "$OUT_DIR" in /*) ;; *) fail "OUT_DIR must be an absolute path" ;; esac
if [ -n "$REPO" ]; then
  case "$OUT_DIR" in "$REPO"|"$REPO"/*) fail "OUT_DIR is inside the git worktree; choose a path outside it" ;; esac
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
[ -z "$(ls -A "$OUT_DIR")" ] || fail "OUT_DIR is not empty; refusing to overwrite an existing CA"

# Name constraints (critical), identical on both CAs: DNS only under the namespace, the exact service host allowed,
# every IPv4 and IPv6 address excluded. The JDK enforces these on the issuing CA, which must be in the served chain.
NC="critical,permitted;DNS:.$NAMESPACE,permitted;DNS:$SERVICE_HOST,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT_DIR/root.key" 2>/dev/null
chmod 600 "$OUT_DIR/root.key"
openssl req -x509 -new -key "$OUT_DIR/root.key" -days "$ROOT_DAYS" -sha256 \
  -subj "/CN=carelog-dev-root-ca" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "nameConstraints=$NC" \
  -out "$OUT_DIR/root.crt" 2>/dev/null || fail "root certificate generation failed"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT_DIR/issuing.key" 2>/dev/null
chmod 600 "$OUT_DIR/issuing.key"
openssl req -new -key "$OUT_DIR/issuing.key" -subj "/CN=carelog-dev-issuing-ca" -out "$OUT_DIR/issuing.csr" 2>/dev/null
ext="$OUT_DIR/issuing.ext"
printf '%s\n' "basicConstraints=critical,CA:TRUE,pathlen:0" "keyUsage=critical,keyCertSign,cRLSign" \
  "subjectKeyIdentifier=hash" "authorityKeyIdentifier=keyid" "nameConstraints=$NC" > "$ext"
openssl x509 -req -in "$OUT_DIR/issuing.csr" -CA "$OUT_DIR/root.crt" -CAkey "$OUT_DIR/root.key" \
  -set_serial "0x$(openssl rand -hex 16)" -days "$ISSUING_DAYS" -sha256 -extfile "$ext" \
  -out "$OUT_DIR/issuing.crt" 2>/dev/null || fail "issuing CA signing failed"
rm -f "$OUT_DIR/issuing.csr" "$ext"
openssl verify -CAfile "$OUT_DIR/root.crt" "$OUT_DIR/issuing.crt" >/dev/null 2>&1 || fail "issuing CA does not verify against root"

cp "$OUT_DIR/root.crt" "$OUT_DIR/ca-bundle.pem"
printf 'NAMESPACE=%s\nSERVICE_HOST=%s\n' "$NAMESPACE" "$SERVICE_HOST" > "$OUT_DIR/constraints.env"
chmod 644 "$OUT_DIR/root.crt" "$OUT_DIR/issuing.crt" "$OUT_DIR/ca-bundle.pem" "$OUT_DIR/constraints.env"

echo "make-root: two-tier CA written to $OUT_DIR"
openssl x509 -in "$OUT_DIR/root.crt" -noout -subject -enddate
openssl x509 -in "$OUT_DIR/issuing.crt" -noout -subject -enddate
cat <<MSG
make-root: next steps (operator)
  1. Move root.key to offline storage (encrypted medium, password-manager attachment). Keep one tested copy off this host.
     Then remove the host copy (Linux: shred -u; macOS: rm -P). Root.key is not needed for daily issuance.
  2. issuing.key stays on the issuing host only, in a restricted directory. It signs every leaf. Never put it in the bundle,
     the repo, Secrets Manager, or any task-readable place. Back it up with the same care as root.key.
  3. Only ca-bundle.pem (the root) goes into the trust-init image. It holds no key.
  4. Issue leaves with ca/issue-leaf.sh. The bundle carries leaf + issuing CA (public), never a CA key.
MSG
