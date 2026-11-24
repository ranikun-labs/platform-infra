#!/bin/sh
# Proxy entrypoint: positive and negative cases for the 1-secret bundle and the 3-secret fallback.
# Usage: test-proxy-entrypoint.sh <proxy-image> <material-dir>
# shellcheck source=./lib.sh
. "$(dirname "$0")/lib.sh"
IMG="$1"; M="$2"
NET="carelog-tls-test-$$"; META="carelog-tls-test-meta-$$"; CASE="carelog-tls-test-case-$$"
cleanup() { docker rm -f "$CASE" "$META" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM
docker network create "$NET" >/dev/null
# Metadata stub: returns the task IP the proxy binds to (loopback inside the sidecar).
docker run -d --name "$META" --network "$NET" --entrypoint sh "$IMG" -c \
  'echo "{\"Containers\":[{\"Networks\":[{\"IPv4Addresses\":[\"127.0.0.1\"]}]}]}" > /usr/share/nginx/html/task && exec nginx -g "daemon off;"' >/dev/null
sleep 2

# run_case <label> <pass|fail> <message-substring or -> <env args...>
run_case() {
  label=$1; expect=$2; want=$3; shift 3
  docker rm -f "$CASE" >/dev/null 2>&1
  docker run -d --name "$CASE" --network "$NET" -e ECS_CONTAINER_METADATA_URI_V4="http://$META" "$@" "$IMG" >/dev/null
  i=0
  while [ $i -lt 20 ]; do
    st=$(docker inspect -f '{{.State.Status}}' "$CASE")
    [ "$st" = exited ] && break
    docker logs "$CASE" 2>&1 | grep -q 'test is successful' && break
    i=$((i + 1)); sleep 1
  done
  st=$(docker inspect -f '{{.State.Status}}' "$CASE"); code=$(docker inspect -f '{{.State.ExitCode}}' "$CASE")
  logs=$(docker logs "$CASE" 2>&1)
  if [ "$expect" = pass ]; then
    if [ "$st" = running ] && echo "$logs" | grep -q 'test is successful'; then pass "$label"
    else fail "$label" "status=$st code=$code $(echo "$logs" | tail -2 | tr '\n' ' ')"; fi
  else
    if [ "$st" = exited ] && [ "$code" != 0 ] && { [ "$want" = - ] || echo "$logs" | grep -q -- "$want"; }; then
      # No secret body may appear in the logs (second line of the key, if any).
      if [ -f "$M/leaf1.key" ] && echo "$logs" | grep -qF "$(sed -n 2p "$M/leaf1.key")"; then fail "$label" "key material leaked into logs"
      else pass "$label"; fi
    else fail "$label" "status=$st code=$code want='$want' $(echo "$logs" | tail -1)"; fi
  fi
  docker rm -f "$CASE" >/dev/null 2>&1
}

b() { cat "$M/$1"; }
run_case "1-secret: matching leaf and key pass" pass - -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "1-secret: second leaf (CA2-signed) passes" pass - -e TLS_BUNDLE_JSON="$(b bundle-ok2.json)"
run_case "3-secret: matching pair passes" pass - -e TLS_CERT_PEM="$(b leaf1.crt)" -e TLS_KEY_PEM="$(b leaf1.key)"
run_case "1-secret: certificate/key mismatch refused" fail "do not match" -e TLS_BUNDLE_JSON="$(b bundle-mismatch.json)"
run_case "1-secret: expired certificate refused" fail "expired" -e TLS_BUNDLE_JSON="$(b bundle-expired.json)"
run_case "1-secret: SAN mismatch refused" fail "SAN" -e TLS_BUNDLE_JSON="$(b bundle-wrongsan.json)"
run_case "SAN: case-insensitive exact match passes" pass - -e TLS_BUNDLE_JSON="$(b bundle-san-case.json)"
run_case "SAN: trailing dot on the certificate name passes" pass - -e TLS_BUNDLE_JSON="$(b bundle-san-dot.json)"
run_case "SAN: list with the name among other entries passes" pass - -e TLS_BUNDLE_JSON="$(b bundle-san-list.json)"
run_case "SAN: prefix (x.name) refused" fail "SAN" -e TLS_BUNDLE_JSON="$(b bundle-san-prefix.json)"
run_case "SAN: suffix (name.evil) refused" fail "SAN" -e TLS_BUNDLE_JSON="$(b bundle-san-suffix.json)"
run_case "SAN: wildcard certificate refused" fail "SAN" -e TLS_BUNDLE_JSON="$(b bundle-san-wild.json)"
run_case "SAN: IP-only certificate refused" fail "SAN" -e TLS_BUNDLE_JSON="$(b bundle-san-iponly.json)"
run_case "expected name: substring of the SAN refused" fail "SAN" -e TLS_EXPECTED_DNS_SAN=carelog-dev-api.dev.internal -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "expected name: upper case matches case-insensitively" pass - -e TLS_EXPECTED_DNS_SAN=RANIKUN-CARELOG-DEV-API.DEV.INTERNAL -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "expected name: wildcard refused" fail "not a plain DNS name" -e TLS_EXPECTED_DNS_SAN="*.dev.internal" -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "expected name: newline injection refused" fail "not a plain DNS name" -e TLS_EXPECTED_DNS_SAN="$(printf 'ranikun-carelog-dev-api.dev.internal\nDNS:evil')" -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "expected name: regex metacharacters refused" fail "not a plain DNS name" -e TLS_EXPECTED_DNS_SAN="ranikun.*" -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "1-secret: expected name is a variable (override refuses valid bundle)" fail "SAN" -e TLS_EXPECTED_DNS_SAN=other.invalid -e TLS_BUNDLE_JSON="$(b bundle-ok.json)"
run_case "1-secret: CA certificate in leaf slot refused (swap)" fail "not a leaf" -e TLS_BUNDLE_JSON="$(b bundle-swap-ca.json)"
run_case "1-secret: certificate placed in key field refused" fail "contains a certificate" -e TLS_BUNDLE_JSON="$(b bundle-key-field-cert.json)"
run_case "1-secret: key placed in certificate field refused" fail "contains a private key" -e TLS_BUNDLE_JSON="$(b bundle-fields-swapped.json)"
run_case "1-secret: chain in certificate field refused" fail "exactly one certificate" -e TLS_BUNDLE_JSON="$(b bundle-chain.json)"
run_case "1-secret: non-PEM certificate refused" fail "exactly one certificate" -e TLS_BUNDLE_JSON="$(b bundle-garbage-cert.json)"
run_case "1-secret: bundle without key refused" fail "no tls_private_key" -e TLS_BUNDLE_JSON="$(b bundle-nokey.json)"
run_case "1-secret: non-JSON bundle refused" fail "not a JSON object" -e TLS_BUNDLE_JSON="$(b bundle-not-json.txt)"
run_case "3-secret: certificate from one leaf, key from another refused" fail "do not match" -e TLS_CERT_PEM="$(b leaf2.crt)" -e TLS_KEY_PEM="$(b leaf1.key)"
run_case "no TLS input refused" fail "TLS" 

summary test-proxy-entrypoint
