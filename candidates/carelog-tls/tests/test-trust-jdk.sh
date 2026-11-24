#!/bin/sh
# JDK client in the trust-init (Core-based) image against the TLS proxy, with the store produced by
# trust-init. Covers: 1-CA and 2-CA stores, CA1 and CA2 leaves, wrong name, default-only store.
# Usage: test-trust-jdk.sh <proxy-image> <trust-image> <material-dir> [javac-image]
. "$(dirname "$0")/lib.sh"
PROXY_IMG="$1"; TRUST="$2"; M="$3"; JAVAC_IMG="${4:-eclipse-temurin:21-jdk}"
W=$(make_work jdk)
NET="carelog-tls-jdk-$$"; PX="carelog-tls-jdk-proxy-$$"; MT="carelog-tls-jdk-meta-$$"
NAME=ranikun-carelog-dev-api.dev.internal; PROXY_IP=10.250.9.10; META_IP=10.250.9.20
JTO="-Djavax.net.ssl.trustStore=/run/carelog-trust/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
VT="carelog-tls-jdk-t-$$"; VT2="carelog-tls-jdk-t2-$$"
cleanup() { docker rm -f "$PX" "$MT" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; docker volume rm -f "$VT" "$VT2" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT INT TERM

# Compile the probe (TlsProbe.java from the candidate) with a JDK image, output in the work dir.
cp "$CANDIDATE_DIR/TlsProbe.java" "$W/"
if docker run --rm -v "$(host_path "$W"):/p" -w /p "$JAVAC_IMG" javac TlsProbe.java >/dev/null 2>&1 && [ -f "$W/TlsProbe.class" ]; then
  pass "probe compiled with JDK image"
else fail "probe compiled with JDK image" "needs $JAVAC_IMG"; summary test-trust-jdk; exit $?; fi

docker network create --subnet 10.250.9.0/24 "$NET" >/dev/null
docker run -d --name "$MT" --network "$NET" --ip $META_IP --entrypoint sh "$PROXY_IMG" -c \
  "echo '{\"Containers\":[{\"Networks\":[{\"IPv4Addresses\":[\"$PROXY_IP\"]}]}]}' > /usr/share/nginx/html/task && exec nginx -g 'daemon off;'" >/dev/null
sleep 2

start_proxy() { # bundle file name in material dir
  docker rm -f "$PX" >/dev/null 2>&1
  docker run -d --name "$PX" --network "$NET" --ip $PROXY_IP --network-alias "$NAME" \
    -e ECS_CONTAINER_METADATA_URI_V4="http://$META_IP" -e TLS_BUNDLE_JSON="$(cat "$M/$1")" "$PROXY_IMG" >/dev/null
  i=0
  while [ $i -lt 25 ]; do docker logs "$PX" 2>&1 | grep -q 'test is successful' && break; i=$((i + 1)); sleep 1; done
  if docker logs "$PX" 2>&1 | grep -q 'test is successful'; then pass "proxy starts with $1"
  else fail "proxy starts with $1" "$(docker logs "$PX" 2>&1 | tail -1)"; fi
}

# probe <label> <ok|fail> <volume-or-none> <url>: ok means the TLS handshake succeeded (proxy answers 403).
probe() {
  label=$1; expect=$2; vol=$3; url=$4
  mounts="-v $(host_path "$W"):/p"
  if [ "$vol" = none ]; then cmd="java -cp /p TlsProbe $url"; else mounts="$mounts -v $vol:/run/carelog-trust"; cmd="java -cp /p TlsProbe $url"; fi
  out=$(docker run --rm --network "$NET" $mounts -e JAVA_TOOL_OPTIONS="$JTO" --entrypoint sh "$TRUST" -c "$cmd" 2>&1)
  if echo "$out" | grep -q '^HTTP 403'; then got=ok; else got=fail; fi
  if [ "$got" = "$expect" ]; then pass "$label"; else fail "$label" "expected $expect: $(echo "$out" | tail -1)"; fi
}

# Phase 1: leaf signed by CA1.
start_proxy bundle-ok.json
docker volume rm -f "$VT" "$VT2" >/dev/null 2>&1
docker run --rm -v "$VT:/run/carelog-trust" "$TRUST" >/dev/null 2>&1 && pass "trust-init with baked CA (1 CA) succeeds" || fail "trust-init with baked CA succeeds"
docker run --rm -v "$VT2:/run/carelog-trust" -v "$(host_path "$M/ca-bundle-2.pem"):/ca/b.pem:ro" -e CARELOG_CA_BUNDLE=/ca/b.pem "$TRUST" >/dev/null 2>&1 && pass "trust-init with 2-CA bundle succeeds" || fail "trust-init with 2-CA bundle succeeds"
probe "1-CA store, CA1 leaf, by name" ok "$VT" "https://$NAME:8443/"
probe "2-CA store, CA1 leaf, by name" ok "$VT2" "https://$NAME:8443/"
probe "2-CA store, CA1 leaf, by IP (no IP SAN)" fail "$VT2" "https://$PROXY_IP:8443/"
probe "default store only (no trust-init), CA1 leaf" fail none "https://$NAME:8443/"

# Phase 2: leaf signed by CA2 (rotation overlap).
start_proxy bundle-ok2.json
probe "2-CA store, CA2 leaf, by name" ok "$VT2" "https://$NAME:8443/"
probe "1-CA store (CA1 only), CA2 leaf" fail "$VT" "https://$NAME:8443/"

summary test-trust-jdk
