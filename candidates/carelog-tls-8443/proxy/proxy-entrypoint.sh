#!/bin/sh
# Starts the carelog TLS front proxy (8443 only). Values are never printed; errors name the failed check only.
#
# Required environment:
#   TLS_BUNDLE_JSON        one Secrets Manager string: {"tls_certificate": "<leaf PEM>[<issuing CA PEM>]", "tls_private_key": "<leaf key PEM>"}
#   TLS_EXPECTED_DNS_SAN   the exact DNS name Core dials: <service_name>.<namespace_name>. No default on purpose.
#                          Also the only Host value the listener accepts (anything else gets 421).
#   TLS_ROOT_CA_PEM        PUBLIC root CA certificate (PEM, CA certificates only, no key). The chain must verify to it.
#                          Public, so it may be an ordinary environment variable. Never a secret.
#   ECS_CONTAINER_METADATA_URI_V4   set by ECS (the task IPv4 is read from it)
# Optional:
#   TWO_TIER_REQUIRED      "true" (default): tls_certificate must be leaf + issuing CA. "false": leaf alone is accepted
#                          (transition only; still verified to TLS_ROOT_CA_PEM).
# Path overrides (tests only; the image uses the defaults):
#   CARELOG_NGINX_DIR      default /etc/nginx          (nginx.conf, conf.d/, templates/)
#   CARELOG_TLS_RUN_DIR    default /run/carelog-tls    (server.crt, server.key, scratch files)
set -eu
umask 077

NGINX_DIR="${CARELOG_NGINX_DIR:-/etc/nginx}"
TLS_DIR="${CARELOG_TLS_RUN_DIR:-/run/carelog-tls}"
NGINX_CONF="$NGINX_DIR/nginx.conf"
TEMPLATE="$NGINX_DIR/templates/carelog-tls.conf.template"
RENDERED="$NGINX_DIR/conf.d/default.conf"
CERT_FILE="$TLS_DIR/server.crt"
KEY_FILE="$TLS_DIR/server.key"
ROOT_FILE="$TLS_DIR/root-ca.pem"

fail() {
  rm -f "$CERT_FILE" "$KEY_FILE" "$ROOT_FILE" "$TLS_DIR"/cert-*.pem "$TLS_DIR"/rootsplit-*.pem
  echo "proxy-entrypoint: $1" >&2
  exit 1
}

: "${ECS_CONTAINER_METADATA_URI_V4:?ECS metadata endpoint required}"
[ -n "${TLS_BUNDLE_JSON:-}" ] || fail "TLS_BUNDLE_JSON required"
[ -n "${TLS_EXPECTED_DNS_SAN:-}" ] || fail "TLS_EXPECTED_DNS_SAN required"
[ -n "${TLS_ROOT_CA_PEM:-}" ] || fail "TLS_ROOT_CA_PEM required (public root certificate)"
TWO_TIER="${TWO_TIER_REQUIRED:-true}"
case "$TWO_TIER" in true|false) ;; *) fail "TWO_TIER_REQUIRED must be true or false" ;; esac

# Expected name: one plain DNS name (letters, digits, '.', '-'; no wildcard, space, newline or regex).
case "$TLS_EXPECTED_DNS_SAN" in
  *[!A-Za-z0-9.-]*) fail "TLS_EXPECTED_DNS_SAN is not a plain DNS name" ;;
esac
EXPECTED_SAN="$(printf '%s' "$TLS_EXPECTED_DNS_SAN" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
[ -n "$EXPECTED_SAN" ] || fail "TLS_EXPECTED_DNS_SAN is empty"

# One Secrets Manager read gives both fields, so the certificate and key come from the same version.
printf '%s' "$TLS_BUNDLE_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || fail "TLS_BUNDLE_JSON is not a JSON object"
CERT_PEM="$(printf '%s' "$TLS_BUNDLE_JSON" | jq -er '.tls_certificate | select(type == "string" and length > 0)' 2>/dev/null)" \
  || fail "TLS_BUNDLE_JSON has no tls_certificate string"
KEY_PEM="$(printf '%s' "$TLS_BUNDLE_JSON" | jq -er '.tls_private_key | select(type == "string" and length > 0)' 2>/dev/null)" \
  || fail "TLS_BUNDLE_JSON has no tls_private_key string"
unset TLS_BUNDLE_JSON

mkdir -p "$TLS_DIR"
printf '%s\n' "$CERT_PEM" > "$CERT_FILE"
printf '%s\n' "$KEY_PEM" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
printf '%s\n' "$TLS_ROOT_CA_PEM" > "$ROOT_FILE"
chmod 644 "$ROOT_FILE"
unset CERT_PEM KEY_PEM TLS_ROOT_CA_PEM

# Fields: the certificate field holds certificates only (no key of any kind); the key field holds only a key.
grep -q 'PRIVATE KEY' "$CERT_FILE" && fail "tls_certificate contains a private key (fields swapped, or a CA key in the bundle?)"
grep -q 'CERTIFICATE' "$KEY_FILE" && fail "tls_private_key contains a certificate (fields swapped?)"
grep -q 'PRIVATE KEY' "$ROOT_FILE" && fail "TLS_ROOT_CA_PEM contains a private key; it must be the public root only"

# Split the chain: cert-1 is the leaf, cert-2 (optional) the issuing CA. More than two is refused.
awk -v d="$TLS_DIR" '/BEGIN CERTIFICATE/ { n++; f = sprintf("%s/cert-%d.pem", d, n) } f { print > f } /END CERTIFICATE/ { close(f); f = "" }' "$CERT_FILE"
N=$(ls "$TLS_DIR"/cert-*.pem 2>/dev/null | wc -l | tr -d ' ')
[ "$N" -ge 1 ] || fail "tls_certificate has no certificate"
LEAF="$TLS_DIR/cert-1.pem"
INTER="$TLS_DIR/cert-2.pem"

# Leaf checks (before chain-shape checks, so a CA in the leaf slot is reported as such).
openssl x509 -in "$LEAF" -noout 2>/dev/null || fail "server certificate does not parse as X.509 PEM"
openssl pkey -in "$KEY_FILE" -noout 2>/dev/null || fail "server private key does not parse as PEM"
openssl x509 -in "$LEAF" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:FALSE' \
  || fail "server certificate is not a leaf (basicConstraints CA:FALSE required)"
openssl x509 -in "$LEAF" -noout -checkend 0 >/dev/null 2>&1 || fail "server certificate is expired"

# SAN check: each DNS entry is compared as a whole value (lower case, trailing dot removed).
# No substring, prefix, suffix, wildcard or regex matching. IP and other SAN types never match.
openssl x509 -in "$LEAF" -noout -ext subjectAltName 2>/dev/null \
  | tr -d '\r' \
  | awk -v want="$EXPECTED_SAN" '
      {
        n = split($0, parts, ",")
        for (i = 1; i <= n; i++) {
          entry = parts[i]
          gsub(/^[ \t]+|[ \t]+$/, "", entry)
          if (substr(entry, 1, 4) != "DNS:") continue
          value = tolower(substr(entry, 5))
          sub(/\.$/, "", value)
          if (value == want) found = 1
        }
      }
      END { exit (found ? 0 : 1) }' \
  || fail "server certificate SAN does not contain the expected DNS name"

# Pair check: leaf certificate and key must carry the same public key.
cert_pub="$(openssl x509 -in "$LEAF" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)" \
  || fail "cannot read certificate public key"
key_pub="$(openssl pkey -in "$KEY_FILE" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" \
  || fail "cannot read private key public key"
[ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] \
  || fail "server certificate and private key do not match (check both values come from the same secret version)"

# Chain shape.
[ "$N" -le 2 ] || fail "tls_certificate holds $N certificates; at most two (leaf, then issuing CA)"
if [ "$N" -eq 1 ]; then
  [ "$TWO_TIER" = false ] || fail "two-tier chain required: tls_certificate must be the leaf followed by the issuing CA"
else
  # Issuing CA: CA:TRUE with pathlen 0 and critical name constraints. A root or a non-constrained CA is refused.
  openssl x509 -in "$INTER" -noout 2>/dev/null || fail "issuing CA does not parse as X.509 PEM"
  openssl x509 -in "$INTER" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE, pathlen:0' \
    || fail "issuing CA must be CA:TRUE with pathlen:0"
  openssl x509 -in "$INTER" -noout -ext nameConstraints 2>/dev/null | grep -q 'Name Constraints: critical' \
    || fail "issuing CA must carry critical nameConstraints"
  openssl x509 -in "$INTER" -noout -checkend 0 >/dev/null 2>&1 || fail "issuing CA is expired"
fi

# Trust root: every certificate in TLS_ROOT_CA_PEM must be a CA; the chain must verify to it with the SAN host checked.
ROOT_N=$(grep -c 'BEGIN CERTIFICATE' "$ROOT_FILE" || true)
[ "$ROOT_N" -ge 1 ] || fail "TLS_ROOT_CA_PEM holds no certificate"
awk -v d="$TLS_DIR" '/BEGIN CERTIFICATE/ { n++; f = sprintf("%s/rootsplit-%d.pem", d, n) } f { print > f } /END CERTIFICATE/ { close(f); f = "" }' "$ROOT_FILE"
for r in "$TLS_DIR"/rootsplit-*.pem; do
  openssl x509 -in "$r" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' \
    || fail "TLS_ROOT_CA_PEM contains a certificate that is not a CA"
done
rm -f "$TLS_DIR"/rootsplit-*.pem

if [ "$N" -eq 2 ]; then
  openssl verify -CAfile "$ROOT_FILE" -untrusted "$INTER" -verify_hostname "$EXPECTED_SAN" "$LEAF" >/dev/null 2>&1 \
    || fail "certificate chain does not verify to TLS_ROOT_CA_PEM for the expected name (name constraints included)"
else
  openssl verify -CAfile "$ROOT_FILE" -verify_hostname "$EXPECTED_SAN" "$LEAF" >/dev/null 2>&1 \
    || fail "certificate does not verify to TLS_ROOT_CA_PEM for the expected name"
fi
rm -f "$TLS_DIR"/cert-*.pem

TASK_IPV4="$(wget -q -T 5 -O - "$ECS_CONTAINER_METADATA_URI_V4/task" \
  | jq -er '[.Containers[].Networks[]?.IPv4Addresses[]?][0]')" || fail "cannot read task IPv4 from metadata"
case "$TASK_IPV4" in *[!0-9.]*|'') fail "invalid task IPv4" ;; esac

# Render. sed replaces fixed placeholders only; nginx variables such as $host are left untouched.
sed -e "s|__TASK_IPV4__|$TASK_IPV4|g" \
    -e "s|__TLS_DIR__|$TLS_DIR|g" \
    -e "s|__TLS_EXPECTED_DNS_SAN__|$EXPECTED_SAN|g" \
    "$TEMPLATE" > "$RENDERED"
nginx -c "$NGINX_CONF" -t
rm -f "$ROOT_FILE"
echo "proxy-entrypoint: ready (TLS 8443 on task IP for $EXPECTED_SAN, chain=$N certificate(s), upstream loopback 8080)"
exec nginx -c "$NGINX_CONF" -g 'daemon off;'
