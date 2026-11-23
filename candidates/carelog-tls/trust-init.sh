#!/bin/sh
set -eu
umask 077
cp "$JAVA_HOME/lib/security/cacerts" /run/carelog-trust/cacerts
printf '%s\n' "$CARELOG_CA_PEM" > /run/carelog-trust/ca.pem
keytool -importcert -noprompt -alias carelog-dev-ca -file /run/carelog-trust/ca.pem -keystore /run/carelog-trust/cacerts -storepass changeit >/dev/null
rm -f /run/carelog-trust/ca.pem
unset CARELOG_CA_PEM
