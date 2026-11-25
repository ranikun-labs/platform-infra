#!/bin/sh
# The proxy entrypoint must refuse to start (non-zero exit, named check, no "ready" line) for each bad input.
# Every refusal happens before the metadata fetch and before nginx. A valid two-tier bundle is the positive control: it
# passes every local check and stops only at the metadata fetch (ECS endpoint pointed at a closed port).
# Usage: test-entrypoint-negative.sh <workdir> <pki-dir from gen-material.sh>
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:?usage: test-entrypoint-negative.sh <workdir> <pki-dir>}
PKI=${2:?usage: test-entrypoint-negative.sh <workdir> <pki-dir>}
SAN=carelog-dev.test.internal
ROOT_PEM=$(cat "$PKI/ca.crt")
PASS=0
FAIL=0
NGX="$WORK/neg-nginx"
mkdir -p "$NGX/conf.d" "$NGX/templates" "$WORK/neg-tls"
cp "$HERE/proxy/nginx.conf.template" "$NGX/templates/carelog-tls.conf.template"

bundle() {  # cert-chain-file key-file -> compact JSON
  jq -c -n --rawfile c "$1" --rawfile k "$2" '{tls_certificate: $c, tls_private_key: $k}'
}

run_case() {  # name expected-fragment   (env: TLS_EXPECTED_DNS_SAN, TLS_BUNDLE_JSON, optional TLS_ROOT_CA_PEM, TWO_TIER_REQUIRED)
  name=$1; want=$2
  out=$(env -i PATH="$PATH" ECS_CONTAINER_METADATA_URI_V4=http://127.0.0.1:1 \
    TLS_EXPECTED_DNS_SAN="$TLS_EXPECTED_DNS_SAN" TLS_BUNDLE_JSON="$TLS_BUNDLE_JSON" \
    TLS_ROOT_CA_PEM="${TLS_ROOT_CA_PEM-$ROOT_PEM}" \
    ${TWO_TIER_REQUIRED:+TWO_TIER_REQUIRED="$TWO_TIER_REQUIRED"} \
    CARELOG_NGINX_DIR="$NGX" CARELOG_TLS_RUN_DIR="$WORK/neg-tls" \
    sh "$HERE/proxy/proxy-entrypoint.sh" 2>&1)
  code=$?
  if [ "$name" = "valid two-tier bundle passes local checks" ] || [ "$name" = "leaf-only accepted when TWO_TIER_REQUIRED=false" ]; then
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
  unset TLS_ROOT_CA_PEM TWO_TIER_REQUIRED
  if ls "$WORK/neg-tls"/cert-*.pem "$WORK/neg-tls"/rootsplit-*.pem >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); echo "FAIL [$name] split certificate files left in run dir"
  fi
}

# Positive: two-tier bundle; and leaf-only only with the explicit transition switch.
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") run_case "valid two-tier bundle passes local checks" ""
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/good.key") TWO_TIER_REQUIRED=false run_case "leaf-only accepted when TWO_TIER_REQUIRED=false" ""

# Leaf-slot and key-slot refusals.
TLS_EXPECTED_DNS_SAN=wrong.test.internal TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") run_case "SAN mismatch refused" "SAN does not contain"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/wrongsan.crt" "$PKI/wrongsan.key") TWO_TIER_REQUIRED=false run_case "certificate with other SAN refused" "SAN does not contain"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/expired.crt" "$PKI/expired.key") TWO_TIER_REQUIRED=false run_case "expired certificate refused" "expired"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/good.key" "$PKI/good.crt") run_case "swapped fields refused" "fields swapped"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/ca.crt" "$PKI/ca.key") run_case "CA certificate in leaf slot refused" "not a leaf"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good.key") run_case "key from another pair refused" "do not match"

# Chain-shape refusals (two-tier).
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/good.crt" "$PKI/good.key") run_case "leaf-only refused when two-tier required (default)" "two-tier chain required"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-three.crt" "$PKI/good2.key") run_case "three certificates refused" "at most two"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-pathlen1.crt" "$PKI/good2.key") run_case "issuing CA with pathlen 1 refused" "pathlen:0"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-nonc.crt" "$PKI/good2.key") run_case "issuing CA without nameConstraints refused" "nameConstraints"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-with-ca-key.crt" "$PKI/good2.key") run_case "CA private key inside tls_certificate refused" "private key"

# Trust refusals: chain must verify to the configured public root, with name constraints applied.
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-alien.crt" "$PKI/good2.key") run_case "chain from another root refused" "does not verify"
TLS_EXPECTED_DNS_SAN=evil.example.org TLS_BUNDLE_JSON=$(bundle "$PKI/chain-outside.crt" "$PKI/evil2.key") run_case "leaf outside issuing CA constraints refused (name constraints)" "does not verify"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") TLS_ROOT_CA_PEM=$(cat "$PKI/alien-root.crt") run_case "chain refused against a different configured root" "does not verify"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") TLS_ROOT_CA_PEM="$(cat "$PKI/good2.crt")" run_case "non-CA TLS_ROOT_CA_PEM refused" "not a CA"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") TLS_ROOT_CA_PEM="$(cat "$PKI/ca.key")" run_case "TLS_ROOT_CA_PEM holding a key refused" "private key"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") TLS_ROOT_CA_PEM= run_case "missing root refused" "TLS_ROOT_CA_PEM required"

# Input refusals (unchanged from round 1).
TLS_EXPECTED_DNS_SAN='*.test.internal' TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") run_case "wildcard expected name refused" "not a plain DNS name"
TLS_EXPECTED_DNS_SAN= TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") run_case "empty expected name refused" "TLS_EXPECTED_DNS_SAN"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON='not json' run_case "non-JSON bundle refused" "not a JSON object"
TLS_EXPECTED_DNS_SAN=$SAN TLS_BUNDLE_JSON=$(bundle "$PKI/chain-twotier.crt" "$PKI/good2.key") TWO_TIER_REQUIRED=maybe run_case "invalid TWO_TIER_REQUIRED refused" "must be true or false"

echo "SUMMARY negative pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
