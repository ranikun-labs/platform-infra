#!/bin/sh
# Starts the carelog TLS front proxy. Values are never printed; errors name the failed check only.
#
# Required environment:
#   TLS_BUNDLE_JSON        one Secrets Manager string: {"tls_certificate": "<leaf PEM>", "tls_private_key": "<PEM>"}
#   TLS_EXPECTED_DNS_SAN   the exact DNS name Core dials: <service_name>.<namespace_name>. No default on purpose.
#   ECS_CONTAINER_METADATA_URI_V4   set by ECS (the task IPv4 is read from it)
# Optional:
#   CORE_CLAIMS_ON_8080    "true" (default, transition) keeps the old Core claims path on task IP:8080.
#                          "false" is set after the rollback window closes. Gateway routes on 8080 are unaffected.
# Path overrides (tests only; the image uses the defaults):
#   CARELOG_NGINX_DIR      default /etc/nginx          (nginx.conf, conf.d/, templates/)
#   CARELOG_TLS_RUN_DIR    default /run/carelog-tls    (server.crt, server.key)
set -eu
umask 077

NGINX_DIR="${CARELOG_NGINX_DIR:-/etc/nginx}"
TLS_DIR="${CARELOG_TLS_RUN_DIR:-/run/carelog-tls}"
NGINX_CONF="$NGINX_DIR/nginx.conf"
TEMPLATE="$NGINX_DIR/templates/carelog-tls.conf.template"
RENDERED="$NGINX_DIR/conf.d/default.conf"
CLAIMS_INC="$NGINX_DIR/conf.d/claims-8080.inc"
CERT_FILE="$TLS_DIR/server.crt"
KEY_FILE="$TLS_DIR/server.key"

fail() {
  rm -f "$CERT_FILE" "$KEY_FILE"
  echo "proxy-entrypoint: $1" >&2
  exit 1
}

: "${ECS_CONTAINER_METADATA_URI_V4:?ECS metadata endpoint required}"
[ -n "${TLS_BUNDLE_JSON:-}" ] || fail "TLS_BUNDLE_JSON required"
[ -n "${TLS_EXPECTED_DNS_SAN:-}" ] || fail "TLS_EXPECTED_DNS_SAN required"

CLAIMS_ON_8080="${CORE_CLAIMS_ON_8080:-true}"
case "$CLAIMS_ON_8080" in true|false) ;; *) fail "CORE_CLAIMS_ON_8080 must be true or false" ;; esac

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
unset CERT_PEM KEY_PEM

# Shape: the certificate field is exactly one leaf certificate, and the key field is only a key.
grep -q 'PRIVATE KEY' "$CERT_FILE" && fail "tls_certificate contains a private key (fields swapped?)"
[ "$(grep -c 'BEGIN CERTIFICATE' "$CERT_FILE")" -eq 1 ] \
  || fail "tls_certificate must contain exactly one certificate (leaf only, no chain or CA)"
grep -q 'CERTIFICATE' "$KEY_FILE" && fail "tls_private_key contains a certificate (fields swapped?)"

openssl x509 -in "$CERT_FILE" -noout 2>/dev/null || fail "server certificate does not parse as X.509 PEM"
openssl pkey -in "$KEY_FILE" -noout 2>/dev/null || fail "server private key does not parse as PEM"

# Leaf, not a CA (a CA certificate in the leaf slot is a swap).
openssl x509 -in "$CERT_FILE" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:FALSE' \
  || fail "server certificate is not a leaf (basicConstraints CA:FALSE required)"

openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 \
  || fail "server certificate is expired"

# SAN check: each DNS entry is compared as a whole value (lower case, trailing dot removed).
# No substring, prefix, suffix, wildcard or regex matching. IP and other SAN types never match.
openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null \
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

# Pair check: certificate and key must carry the same public key.
cert_pub="$(openssl x509 -in "$CERT_FILE" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)" \
  || fail "cannot read certificate public key"
key_pub="$(openssl pkey -in "$KEY_FILE" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" \
  || fail "cannot read private key public key"
[ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] \
  || fail "server certificate and private key do not match (check both values come from the same secret version)"

TASK_IPV4="$(wget -q -T 5 -O - "$ECS_CONTAINER_METADATA_URI_V4/task" \
  | jq -er '[.Containers[].Networks[]?.IPv4Addresses[]?][0]')" || fail "cannot read task IPv4 from metadata"
case "$TASK_IPV4" in *[!0-9.]*|'') fail "invalid task IPv4" ;; esac

# Transition-only Core claims on 8080: exact UUID path, GET only. Empty file when disabled.
if [ "$CLAIMS_ON_8080" = true ]; then
cat > "$CLAIMS_INC" <<'EOF'
    location ~ "^/api/v1/internal/identity/claims/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$" {
        limit_except GET { deny all; }
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
    }
EOF
else
  : > "$CLAIMS_INC"
fi

# Render. sed replaces fixed placeholders only; nginx variables such as $host are left untouched.
sed -e "s|__TASK_IPV4__|$TASK_IPV4|g" \
    -e "s|__TLS_DIR__|$TLS_DIR|g" \
    -e "s|__NGINX_DIR__|$NGINX_DIR|g" \
    "$TEMPLATE" > "$RENDERED"
nginx -c "$NGINX_CONF" -t
echo "proxy-entrypoint: ready (8080 front claims=$CLAIMS_ON_8080, TLS 8443 for $EXPECTED_SAN)"
exec nginx -c "$NGINX_CONF" -g 'daemon off;'
