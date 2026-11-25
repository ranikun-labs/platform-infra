#!/bin/sh
# The proxy entrypoint must refuse to start (non-zero exit, named check, no "ready" line) for each bad input.
# Every refusal happens before the metadata fetch and before nginx. A valid bundle is the positive control: it
# passes every local check and stops only at the metadata fetch (ECS endpoint pointed at a closed port).
# Usage: test-entrypoint-negative.sh <workdir> <pki-dir from gen-material.sh>
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:?usage: test-entrypoint-negative.sh <workdir> <pki-dir>}
PKI=${2:?usage: test-entrypoint-negative.sh <workdir> <pki-dir>}
SAN=carelog-dev.test.internal
PASS=0
FAIL=0
NGX="$WORK/neg-nginx"
mkdir -p "$NGX/conf.d" "$NGX/templates" "$WORK/neg-tls"
cp "$HERE/proxy/nginx.conf.template" "$NGX/templates/carelog-tls.conf.template"

bundle() {  # cert_file key_file -> compact JSON
  jq -c -n --rawfile c "$1" --rawfile k "$2" '{tls_certificate: $c, tls_private_key: $k}'
}

run_case() {  # name expected-fragment   (inputs: TLS_EXPECTED_DNS_SAN, TLS_BUNDLE_JSON)
  name=$1; want=$2
  out=$(env -i PATH="$PATH" ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:1 \
    TLS_EXPECTED_DNS_SAN="$TLS_EXPECTED_DNS_SAN" TLS_BUNDLE_JSON="$TLS_BUNDLE_JSON" \
    CARELOG_NGINX_DIR="$NGX" CARELOG_TLS_RUN_DIR="$WORK/neg-tls" \
    sh "$HERE/proxy/proxy-entrypoint.sh" 2>&1)
  code=$?
  if [ "$name" = "valid bundle passes local checks" ]; then
    if printf '%s' "$out" | grep -q 'cannot read task IPv4'; then
      PASS=$((PASS + 1)); echo "PASS [$name] stopped at metadata fetch only"
    else
      FAIL=$((FAIL + 1)); echo "FAIL [$name] out=$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
  elif [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q -- "$want" && ! printf '%s' "$out" | grep -q 'ready'; then
    PASS=$((PASS + 1)); echo "PASS [$name] exit=$code: $(printf '%s' "$out" | grep 'proxy-entrypoint' | head -1)"
  else
    FAIL=$((FAIL + 1)); echo "FAIL [$name] exit=$code want='$want' out=$(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  fi
}

TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/good.key") run_case "valid bundle passes local checks" ""
TLS_EXPECTED_DNS_SAN=wrong.test.internal TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/good.key") run_case "SAN mismatch refused" "SAN does not contain"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/wrongsan.crt" "$PKI/wrongsan.key") run_case "certificate with other SAN refused" "SAN does not contain"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/expired.crt" "$PKI/expired.key") run_case "expired certificate refused" "expired"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/good.key" "$PKI/good.crt") run_case "swapped fields refused" "fields swapped"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/ca.crt" "$PKI/ca.key") run_case "CA certificate in leaf slot refused" "not a leaf"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/wrongsan.key") run_case "key from another pair refused" "do not match"
cat "$PKI/good.crt" "$PKI/ca.crt" > "$WORK/chain.crt"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$WORK/chain.crt" "$PKI/good.key") run_case "chain in certificate slot refused" "exactly one certificate"
TLS_EXPECTED_DNS_SAN='*.test.internal' TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/good.key") run_case "wildcard expected name refused" "not a plain DNS name"
TLS_EXPECTED_DNS_SAN= TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/good.key") run_case "empty expected name refused" "TLS_EXPECTED_DNS_SAN"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON='not json' run_case "non-JSON bundle refused" "not a JSON object"

echo "SUMMARY negative pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
