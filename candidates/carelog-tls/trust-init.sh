#!/bin/sh
# Builds the per-task truststore for the Core app: starts from the Core image's own cacerts
# (JAVA_HOME/lib/security/cacerts, copied, never replaced) and ADDS the Carelog DEV CA certificate(s).
# Input: a PUBLIC PEM bundle baked into the image at build time (CA certificates only, no keys).
# Rotation = rebuild the image with the new bundle. Values are never printed.
# Output: /run/carelog-trust/cacerts (readable by the Core app, which mounts the volume read-only).
# Rejected (container exits non-zero before writing the output): empty bundle, non-PEM content,
# any private key, a certificate that is not a CA (basicConstraints CA:TRUE), an expired CA, or a
# store that does not grow by exactly the number of imported certificates.
set -eu
: "${JAVA_HOME:?JAVA_HOME required}"
CA_BUNDLE="${CARELOG_CA_BUNDLE:-/usr/local/share/carelog/carelog-dev-ca-bundle.pem}"
TRUST_DIR="${CARELOG_TRUST_DIR:-/run/carelog-trust}"
SPLIT_DIR="$TRUST_DIR/ca-split"
STORE="$TRUST_DIR/cacerts.work"
FINAL="$TRUST_DIR/cacerts"
ALIAS_PREFIX=carelog-dev-ca
# Public JDK default integrity password for cacerts. It protects no private material.
STORE_PASS=changeit

fail() { echo "trust-init: $1" >&2; exit 1; }

[ -r "$CA_BUNDLE" ] || fail "CA bundle not readable"
[ -s "$CA_BUNDLE" ] || fail "CA bundle is empty"
grep -q 'PRIVATE KEY' "$CA_BUNDLE" && fail "CA bundle contains private key material; refusing"
begin_count=$(grep -c '^-----BEGIN CERTIFICATE-----$' "$CA_BUNDLE" || true)
end_count=$(grep -c '^-----END CERTIFICATE-----$' "$CA_BUNDLE" || true)
[ "$begin_count" -ge 1 ] || fail "CA bundle contains no PEM certificate"
[ "$begin_count" -eq "$end_count" ] || fail "CA bundle has unbalanced PEM blocks"
# Only PEM framing and base64 lines are allowed. Anything else means the input is not a PEM bundle.
bad_lines=$(grep -c -v -E '^(-----(BEGIN|END) CERTIFICATE-----|[A-Za-z0-9+/=]+|)$' "$CA_BUNDLE" || true)
[ "$bad_lines" -eq 0 ] || fail "CA bundle contains non-PEM content"

umask 077
# Partial work never becomes the output: the store is written under a working name and moved into place last.
trap 'rm -rf "$SPLIT_DIR" "$STORE"' EXIT
mkdir -p "$TRUST_DIR"
rm -rf "$SPLIT_DIR"; mkdir -p "$SPLIT_DIR"
cp "$JAVA_HOME/lib/security/cacerts" "$STORE"

# Split the bundle into one file per certificate (keytool imports only the first certificate of a file).
awk -v dir="$SPLIT_DIR" '
  /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/ca-%02d.pem", dir, n) }
  f { print > f }
  /-----END CERTIFICATE-----/ { close(f); f = "" }' "$CA_BUNDLE"

store_entries() {
  keytool -list -keystore "$STORE" -storepass "$STORE_PASS" 2>/dev/null \
    | sed -n 's/^Your keystore contains \([0-9][0-9]*\) entr.*/\1/p'
}
before=$(store_entries)
[ -n "$before" ] || fail "cannot read default store"
now=$(date +%s)

i=0
for pem in "$SPLIT_DIR"/ca-*.pem; do
  i=$((i + 1))
  info=$(keytool -printcert -v -file "$pem" 2>/dev/null) || fail "bundle certificate $i does not parse"
  echo "$info" | grep -q 'CA:true' || fail "bundle certificate $i is not a CA (basicConstraints CA:TRUE required)"
  until_text=$(echo "$info" | sed -n 's/.*until: //p' | head -n 1)
  until_epoch=$(date -d "$until_text" +%s 2>/dev/null) || fail "bundle certificate $i has an unreadable validity date"
  [ "$until_epoch" -gt "$now" ] || fail "bundle certificate $i is expired"
  keytool -importcert -noprompt -alias "$ALIAS_PREFIX-$i" -file "$pem" \
    -keystore "$STORE" -storepass "$STORE_PASS" >/dev/null 2>&1 || fail "bundle certificate $i was not imported"
  keytool -list -alias "$ALIAS_PREFIX-$i" -keystore "$STORE" -storepass "$STORE_PASS" >/dev/null
done
rm -rf "$SPLIT_DIR"

after=$(store_entries)
[ "$i" -eq "$begin_count" ] || fail "imported $i of $begin_count bundle certificates"
[ "$((after - before))" -eq "$begin_count" ] || fail "store grew by $((after - before)), expected $begin_count"
# Public CA data only; world-readable so the Core process can read it regardless of its UID.
chmod 644 "$STORE"
mv -f "$STORE" "$FINAL"
echo "trust-init: imported $begin_count CA certificate(s); store entries $before -> $after"
