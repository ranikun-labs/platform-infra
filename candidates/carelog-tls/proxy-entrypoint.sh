#!/bin/sh
# Starts the TLS proxy sidecar. Inputs: TLS_CERT_PEM and TLS_KEY_PEM (plaintext PEM secrets),
# ECS_CONTAINER_METADATA_URI_V4 (set by ECS). Values are never printed.
set -eu
umask 077
: "${ECS_CONTAINER_METADATA_URI_V4:?ECS metadata endpoint required}"
: "${TLS_CERT_PEM:?TLS certificate secret required}"
: "${TLS_KEY_PEM:?TLS private key secret required}"

TASK_IPV4="$(wget -q -T 5 -O - "$ECS_CONTAINER_METADATA_URI_V4/task" | jq -er '[.Containers[].Networks[]?.IPv4Addresses[]?][0]')"
case "$TASK_IPV4" in *[!0-9.]*|'') echo "invalid task IPv4" >&2; exit 1;; esac
export TASK_IPV4

printf '%s\n' "$TLS_CERT_PEM" > /run/carelog-tls/server.crt
printf '%s\n' "$TLS_KEY_PEM" > /run/carelog-tls/server.key
chmod 600 /run/carelog-tls/server.key
unset TLS_CERT_PEM TLS_KEY_PEM

# shellcheck disable=SC2016 # literal variable list for envsubst, not a shell expansion
envsubst '${TASK_IPV4}' < /etc/nginx/templates/carelog.conf > /etc/nginx/conf.d/default.conf
nginx -t
exec nginx -g 'daemon off;'
