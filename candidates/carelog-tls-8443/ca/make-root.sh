#!/bin/sh
# Creates the self-managed Carelog DEV root CA. Run ONCE on an offline operator host, never in CI or in a task.
#   NAMESPACE     DNS namespace the CA may sign for, e.g. dev.carelog.internal (leading dot form is enforced below)
#   SERVICE_HOST  the exact name Core dials, <service_name>.<namespace_name>, e.g. carelog-dev.dev.carelog.internal
#   OUT_DIR       operator-chosen directory OUTSIDE this git worktree. Created 0700. Must not already hold files.
# Writes:
#   root.key       CA private key, mode 0600. Never copy it into the repo, a task volume, or any secret that tasks can read.
#   root.crt       public CA certificate (CA:TRUE, pathlen:0, nameConstraints).
#   ca-bundle.pem  public copy of root.crt for trust-init (the only CA file that goes into the image).
#   constraints.env  public record of NAMESPACE and SERVICE_HOST, read by issue-leaf.sh.
# Validity: 730 days (2 years). ECDSA P-256.
set -eu
umask 077
fail() { echo "make-root: $1" >&2; exit 1; }

NAMESPACE=${NAMESPACE:?NAMESPACE required, e.g. dev.carelog.internal}
SERVICE_HOST=${SERVICE_HOST:?SERVICE_HOST required, e.g. carelog-dev.dev.carelog.internal}
OUT_DIR=${OUT_DIR:?OUT_DIR required (outside the repo)}
DAYS=${DAYS:-730}

plain_dns() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; }
plain_dns "$NAMESPACE" || fail "NAMESPACE must be a lower-case DNS name with at least two labels"
plain_dns "$SERVICE_HOST" || fail "SERVICE_HOST must be a lower-case DNS name"
case "$SERVICE_HOST" in *".$NAMESPACE") ;; *) fail "SERVICE_HOST must end with .$NAMESPACE" ;; esac

# The CA key must never land inside a git worktree (it would be one 'git add' away from the repo).
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)
case "$OUT_DIR" in /*) ;; *) fail "OUT_DIR must be an absolute path" ;; esac
if [ -n "$REPO" ]; then
  case "$OUT_DIR" in "$REPO"|"$REPO"/*) fail "OUT_DIR is inside the git worktree; choose a path outside it" ;; esac
fi

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
[ -z "$(ls -A "$OUT_DIR")" ] || fail "OUT_DIR is not empty; refusing to overwrite an existing CA"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$OUT_DIR/root.key" 2>/dev/null
chmod 600 "$OUT_DIR/root.key"

# Name constraints (critical): DNS names only under the namespace, the exact service host allowed explicitly,
# and every IPv4/IPv6 address excluded. Because DNS has a permitted list, DNS names outside it are refused by
# any RFC 5280 path validator (JDK PKIX included). Email, URI and directory-name SANs are not constrained here;
# leaves for Core carry DNS only (see issue-leaf.sh).
NC="critical,permitted;DNS:.$NAMESPACE,permitted;DNS:$SERVICE_HOST,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0"
openssl req -x509 -new -key "$OUT_DIR/root.key" -days "$DAYS" -sha256 \
  -subj "/CN=carelog-dev-root-ca" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  -addext "nameConstraints=$NC" \
  -out "$OUT_DIR/root.crt" 2>/dev/null || fail "root certificate generation failed"

cp "$OUT_DIR/root.crt" "$OUT_DIR/ca-bundle.pem"
printf 'NAMESPACE=%s\nSERVICE_HOST=%s\n' "$NAMESPACE" "$SERVICE_HOST" > "$OUT_DIR/constraints.env"
chmod 644 "$OUT_DIR/root.crt" "$OUT_DIR/ca-bundle.pem" "$OUT_DIR/constraints.env"

echo "make-root: root CA written to $OUT_DIR"
openssl x509 -in "$OUT_DIR/root.crt" -noout -subject -enddate
cat <<MSG
make-root: next steps (operator)
  1. Move root.key to offline storage now (password manager attachment or encrypted offline medium). Delete the
     copy on this host once stored (Linux: shred -u; macOS: rm -P). Keep at least one tested copy off this host.
  2. Only ca-bundle.pem goes into the trust-init image (CA_BUNDLE=... build/build-images.sh). It holds no key.
  3. Issue leaves with ca/issue-leaf.sh. The CA key is needed only for issuing and rotation, never at run time.
MSG
