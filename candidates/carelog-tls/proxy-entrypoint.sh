#!/bin/sh
# Starts the TLS proxy sidecar. Values are never printed; errors name the failed check only.
# Inputs (one of the two modes):
#   1-secret (proposed): TLS_BUNDLE_JSON = the whole secret string, a JSON object with keys
#                        "tls_certificate" (one leaf certificate PEM) and "tls_private_key" (PEM).
#                        One Secrets Manager read, so both values come from the same version.
#   3-secret (fallback): TLS_CERT_PEM and TLS_KEY_PEM (plaintext PEM secrets).
# ECS_CONTAINER_METADATA_URI_V4 is set by ECS.
# TLS_EXPECTED_DNS_SAN overrides the expected certificate name (default below).
set -eu
umask 077
: "${ECS_CONTAINER_METADATA_URI_V4:?ECS metadata endpoint required}"
EXPECTED_SAN="${TLS_EXPECTED_DNS_SAN:-ranikun-carelog-dev-api.dev.internal}"
CERT_FILE=/run/carelog-tls/server.crt
KEY_FILE=/run/carelog-tls/server.key

fail() {
  rm -f "$CERT_FILE" "$KEY_FILE"
  echo "proxy-entrypoint: $1" >&2
  exit 1
}

if [ -n "${TLS_BUNDLE_JSON:-}" ]; then
  printf '%s' "$TLS_BUNDLE_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || fail "TLS_BUNDLE_JSON is not a JSON object"
  CERT_PEM="$(printf '%s' "$TLS_BUNDLE_JSON" | jq -er '.tls_certificate | select(type == "string" and length > 0)' 2>/dev/null)" \
    || fail "TLS_BUNDLE_JSON has no tls_certificate string"
  KEY_PEM="$(printf '%s' "$TLS_BUNDLE_JSON" | jq -er '.tls_private_key | select(type == "string" and length > 0)' 2>/dev/null)" \
    || fail "TLS_BUNDLE_JSON has no tls_private_key string"
  unset TLS_BUNDLE_JSON
else
  : "${TLS_CERT_PEM:?TLS certificate secret required}"
  : "${TLS_KEY_PEM:?TLS private key secret required}"
  CERT_PEM="$TLS_CERT_PEM"
  KEY_PEM="$TLS_KEY_PEM"
fi

printf '%s\n' "$CERT_PEM" > "$CERT_FILE"
printf '%s\n' "$KEY_PEM" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
unset TLS_CERT_PEM TLS_KEY_PEM CERT_PEM KEY_PEM

# Shape: the certificate field is exactly one leaf certificate, and the key field is only a key.
grep -q 'PRIVATE KEY' "$CERT_FILE" && fail "tls_certificate contains a private key (fields swapped?)"
[ "$(grep -c 'BEGIN CERTIFICATE' "$CERT_FILE")" -eq 1 ] \
  || fail "tls_certificate must contain exactly one certificate (leaf only, no chain or CA)"
grep -q 'CERTIFICATE' "$KEY_FILE" && fail "tls_private_key contains a certificate (fields swapped?)"

# Parse checks.
openssl x509 -in "$CERT_FILE" -noout 2>/dev/null || fail "server certificate does not parse as X.509 PEM"
openssl pkey -in "$KEY_FILE" -noout 2>/dev/null || fail "server private key does not parse as PEM"

# Leaf, not a CA (a CA certificate in the leaf slot is a swap).
openssl x509 -in "$CERT_FILE" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:FALSE' \
  || fail "server certificate is not a leaf (basicConstraints CA:FALSE required)"

# Validity now.
openssl x509 -in "$CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 \
  || fail "server certificate is expired"

# Expected name: one plain DNS name (letters, digits, '.', '-'; no wildcard, space, newline or regex).
# Normalised to lower case without a trailing dot.
case "$EXPECTED_SAN" in
  *[!A-Za-z0-9.-]*|'') fail "TLS_EXPECTED_DNS_SAN is not a plain DNS name" ;;
esac
EXPECTED_SAN="$(printf '%s' "$EXPECTED_SAN" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
[ -n "$EXPECTED_SAN" ] || fail "TLS_EXPECTED_DNS_SAN is empty"

# SAN check: one awk pass over the certificate's SAN entries. Each entry is compared as a whole
# value (after 'DNS:' and trimming, lower case, trailing dot removed). No substring, prefix, suffix,
# wildcard or regex matching. IP and other SAN types never match a DNS name.
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

# Pair check: the certificate and the key must have the same public key.
cert_pub="$(openssl x509 -in "$CERT_FILE" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)" \
  || fail "cannot read certificate public key"
key_pub="$(openssl pkey -in "$KEY_FILE" -pubout 2>/dev/null | openssl sha256 2>/dev/null)" \
  || fail "cannot read private key public key"
[ -n "$cert_pub" ] && [ "$cert_pub" = "$key_pub" ] \
  || fail "server certificate and private key do not match (check both values come from the same secret version)"

TASK_IPV4="$(wget -q -T 5 -O - "$ECS_CONTAINER_METADATA_URI_V4/task" | jq -er '[.Containers[].Networks[]?.IPv4Addresses[]?][0]')"
case "$TASK_IPV4" in *[!0-9.]*|'') fail "invalid task IPv4" ;; esac
export TASK_IPV4

# shellcheck disable=SC2016 # literal variable list for envsubst, not a shell expansion
envsubst '${TASK_IPV4}' < /etc/nginx/templates/carelog.conf > /etc/nginx/conf.d/default.conf
nginx -t
exec nginx -g 'daemon off;'
