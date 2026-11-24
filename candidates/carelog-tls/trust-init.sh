#!/bin/sh
# Builds the per-task truststore: JDK default cacerts plus the Carelog DEV CA.
# Input: CARELOG_CA_PEM (plaintext PEM from a Secrets Manager secret, not JSON).
# Output: /run/carelog-trust/cacerts (readable by the Core app, which mounts the volume read-only).
set -eu
: "${JAVA_HOME:?JAVA_HOME required}"
: "${CARELOG_CA_PEM:?CA PEM secret required}"
TRUST_DIR=/run/carelog-trust
# Public JDK default integrity password for cacerts. It protects no private material.
STORE_PASS=changeit

umask 077
cp "$JAVA_HOME/lib/security/cacerts" "$TRUST_DIR/cacerts"
printf '%s\n' "$CARELOG_CA_PEM" > "$TRUST_DIR/ca.pem"
unset CARELOG_CA_PEM
keytool -importcert -noprompt -alias carelog-dev-ca -file "$TRUST_DIR/ca.pem" \
  -keystore "$TRUST_DIR/cacerts" -storepass "$STORE_PASS" >/dev/null
rm -f "$TRUST_DIR/ca.pem"
# Fail the init container if the alias is missing after import.
keytool -list -alias carelog-dev-ca -keystore "$TRUST_DIR/cacerts" -storepass "$STORE_PASS" >/dev/null
# Public CA data only; world-readable so the Core process can read it regardless of its UID.
chmod 644 "$TRUST_DIR/cacerts"
