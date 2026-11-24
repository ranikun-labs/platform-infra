#!/bin/sh
# Builds the per-task truststore: JDK default cacerts plus the Carelog DEV CA certificate(s).
# Input: a PUBLIC PEM bundle baked into the image at build time (one or more CA certificates).
#        It is public material, never a secret. Rotation = rebuild the image with the new bundle.
# Output: /run/carelog-trust/cacerts (readable by the Core app, which mounts the volume read-only).
# Each certificate in the bundle is imported under its own alias. The store must grow by exactly
# the number of imported certificates, and every certificate must be a CA (basicConstraints CA:TRUE).
set -eu
: "${JAVA_HOME:?JAVA_HOME required}"
CA_BUNDLE="${CARELOG_CA_BUNDLE:-/usr/local/share/carelog/carelog-dev-ca-bundle.pem}"
TRUST_DIR=/run/carelog-trust
SPLIT_DIR="$TRUST_DIR/ca-split"
STORE="$TRUST_DIR/cacerts"
ALIAS_PREFIX=carelog-dev-ca
# Public JDK default integrity password for cacerts. It protects no private material.
STORE_PASS=changeit

[ -r "$CA_BUNDLE" ] || { echo "CA bundle not readable: $CA_BUNDLE" >&2; exit 1; }
expected=$(grep -c 'BEGIN CERTIFICATE' "$CA_BUNDLE" || true)
case "$expected" in ''|0) echo "CA bundle contains no certificate" >&2; exit 1;; esac

umask 077
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
[ -n "$before" ] || { echo "cannot read default store" >&2; exit 1; }

i=0
for pem in "$SPLIT_DIR"/ca-*.pem; do
  i=$((i + 1))
  # Refuse anything that is not a CA certificate, so a leaf in the bundle cannot become a trust anchor.
  keytool -printcert -v -file "$pem" | grep -q 'CA:true' \
    || { echo "bundle certificate $i is not a CA (basicConstraints CA:TRUE required)" >&2; exit 1; }
  keytool -importcert -noprompt -alias "$ALIAS_PREFIX-$i" -file "$pem" \
    -keystore "$STORE" -storepass "$STORE_PASS" >/dev/null
  keytool -list -alias "$ALIAS_PREFIX-$i" -keystore "$STORE" -storepass "$STORE_PASS" >/dev/null
done
rm -rf "$SPLIT_DIR"

after=$(store_entries)
[ "$i" -eq "$expected" ] || { echo "imported $i of $expected bundle certificates" >&2; exit 1; }
[ "$((after - before))" -eq "$expected" ] \
  || { echo "store grew by $((after - before)), expected $expected" >&2; exit 1; }
# Public CA data only; world-readable so the Core process can read it regardless of its UID.
chmod 644 "$STORE"
echo "trust-init: imported $expected CA certificate(s); store entries $before -> $after"
