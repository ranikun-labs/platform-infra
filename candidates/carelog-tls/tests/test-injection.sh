#!/bin/sh
# Secret injection as ECS does it: one env var TLS_BUNDLE_JSON holding the raw SecretString.
# Checks that PEM newlines survive JSON encoding (env var and env-file variants), and that broken
# encodings are refused by the entrypoint with a clear message and no secret content in the logs.
# Usage: test-injection.sh <proxy-image> <material-dir>
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"
IMG="$1"; M="$2"
W=$(make_work inj); trap 'rm -rf "$W"' EXIT INT TERM

# Round trip: the value ECS injects, read back by the same JSON parser the entrypoint uses.
roundtrip() { # label env-args... ; compares the decoded certificate and key with the originals byte for byte
  label=$1; shift
  docker run --rm "$@" --entrypoint sh "$IMG" -c 'printf "%s" "$TLS_BUNDLE_JSON" | jq -ej .tls_certificate' > "$W/out.crt" 2>/dev/null
  docker run --rm "$@" --entrypoint sh "$IMG" -c 'printf "%s" "$TLS_BUNDLE_JSON" | jq -ej .tls_private_key' > "$W/out.key" 2>/dev/null
  if cmp -s "$W/out.crt" "$M/leaf1.crt" && cmp -s "$W/out.key" "$M/leaf1.key"; then pass "$label: PEM newlines survive (byte-identical)"
  else fail "$label: PEM newlines survive" "round trip differs"; fi
}
roundtrip "env var (ECS-style raw SecretString)" -e TLS_BUNDLE_JSON="$(cat "$M/bundle-ok.json")"

# Env-file variant: one line per variable, value is the compact JSON (no quotes).
printf 'TLS_BUNDLE_JSON=%s\n' "$(cat "$M/bundle-ok.json")" > "$W/env.list"
roundtrip "env-file" --env-file "$(host_path "$W/env.list")"

# Negative encodings: refused before any file is written, message names the problem, no key body in logs.
neg() { # label value expected-substring
  out=$(docker run --rm -e ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:1 -e TLS_BUNDLE_JSON="$2" "$IMG" 2>&1); rc=$?
  if [ $rc -ne 0 ] && echo "$out" | grep -q -- "$3" && ! echo "$out" | grep -qF "$(sed -n 2p "$M/leaf1.key")"; then pass "$1"
  else fail "$1" "rc=$rc $(echo "$out" | tail -1)"; fi
}
neg "raw PEM (not JSON) in the bundle variable refused" "$(cat "$M/leaf1.crt")" "not a JSON object"
DOUBLE=$(perl -pe 's/\\n/\\\\n/g' "$M/bundle-ok.json")
neg "double-escaped newlines refused" "$DOUBLE" "does not parse\|exactly one certificate\|not a leaf"
neg "JSON array instead of object refused" '["a"]' "not a JSON object"
neg "missing tls_private_key refused" "$(cat "$M/bundle-nokey.json")" "no tls_private_key"

summary test-injection
