#!/bin/sh
set -eu
umask 077
: "${ECS_CONTAINER_METADATA_URI_V4:?ECS metadata endpoint required}"
TASK_IPV4="$(wget -qO- "$ECS_CONTAINER_METADATA_URI_V4/task" | jq -er '[.Containers[].Networks[]?.IPv4Addresses[]?][0]')"
case "$TASK_IPV4" in *[!0-9.]*|'') exit 1;; esac
export TASK_IPV4
printf '%s\n' "$TLS_CERT_PEM" > /run/carelog-tls/server.crt
printf '%s\n' "$TLS_KEY_PEM" > /run/carelog-tls/server.key
unset TLS_CERT_PEM TLS_KEY_PEM
envsubst '${TASK_IPV4}' < /etc/nginx/templates/carelog.conf > /etc/nginx/conf.d/default.conf
nginx -t
exec nginx -g 'daemon off;'
