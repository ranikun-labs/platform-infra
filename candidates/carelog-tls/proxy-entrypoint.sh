#!/bin/sh
# Starts the TLS proxy sidecar. Values are never printed.
# Inputs (one of the two modes):
#   1-secret (proposed): TLS_BUNDLE_JSON = JSON with keys "tls_certificate" and "tls_private_key"
#                        (one Secrets Manager secret, injected as the whole secret string, one read).
#   3-secret (fallback): TLS_CERT_PEM and TLS_KEY_PEM (plaintext PEM secrets).
# ECS_CONTAINER_METADATA_URI_V4 is set by ECS.
set -eu
umask 077
: "${ECS_CONTAINER_METADATA_URI_V4:?ECS metadata endpoint required}"

if [ -n "${TLS_BUNDLE_JSON:-}" ]; then
  CERT_PEM="$(printf '%s' "$TLS_BUNDLE_JSON" | jq -er '.tls_certificate // empty')" || { echo "TLS bundle has no tls_certificate" >&2; exit 1; }
  KEY_PEM="$(printf '%s' "$TLS_BUNDLE_JSON" | jq -er '.tls_private_key // empty')" || { echo "TLS bundle has no tls_private_key" >&2; exit 1; }
  unset TLS_BUNDLE_JSON
else
  : "${TLS_CERT_PEM:?TLS certificate secret required}"
  : "${TLS_KEY_PEM:?TLS private key secret required}"
  CERT_PEM="$TLS_CERT_PEM"
  KEY_PEM="$TLS_KEY_PEM"
fi

TASK_IPV4="$(wget -q -T 5 -O - "$ECS_CONTAINER_METADATA_URI_V4/task" | jq -er '[.Containers[].Networks[]?.IPv4Addresses[]?][0]')"
case "$TASK_IPV4" in *[!0-9.]*|'') echo "invalid task IPv4" >&2; exit 1;; esac
export TASK_IPV4

printf '%s\n' "$CERT_PEM" > /run/carelog-tls/server.crt
printf '%s\n' "$KEY_PEM" > /run/carelog-tls/server.key
chmod 600 /run/carelog-tls/server.key
unset TLS_CERT_PEM TLS_KEY_PEM CERT_PEM KEY_PEM

# Fail fast when the certificate and key are not a pair. This happens during a rotation when
# the two values come from different secret versions. Compare SPKI hashes; values are not printed.
cert_pub="$(openssl x509 -in /run/carelog-tls/server.crt -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)" \
  || { echo "server certificate is not a readable X.509 PEM" >&2; exit 1; }
key_pub="$(openssl pkey -in /run/carelog-tls/server.key -pubout 2>/dev/null | openssl sha256 2>/dev/null)" \
  || { echo "server private key is not a readable PEM" >&2; exit 1; }
if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
  rm -f /run/carelog-tls/server.crt /run/carelog-tls/server.key
  echo "server certificate and private key do not match (check both values come from the same secret version)" >&2
  exit 1
fi

# shellcheck disable=SC2016 # literal variable list for envsubst, not a shell expansion
envsubst '${TASK_IPV4}' < /etc/nginx/templates/carelog.conf > /etc/nginx/conf.d/default.conf
nginx -t
exec nginx -g 'daemon off;'
