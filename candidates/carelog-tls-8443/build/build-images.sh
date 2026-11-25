#!/bin/sh
# Builds the two images from this directory and prints the digests Terraform must pin.
#   CORE_IMAGE   required. Digest reference of the SAME Core image the Core task definition runs: repo@sha256:<64 hex>.
#                Tags are refused: a tag can move, and the trust-init base must match the Core task exactly.
#   CA_BUNDLE    required. Path to the PUBLIC Carelog DEV CA bundle (PEM, CA certificates only, no keys).
#   SOURCE_SHA   required. Git commit of this source tree (recorded as an image label).
#   PROXY_REPO   optional. ECR repository URI for the front proxy, e.g. <acct>.dkr.ecr.<region>.amazonaws.com/ranikun/carelog/tls-proxy
#   TRUST_REPO   optional. ECR repository URI for trust-init, e.g. <acct>.dkr.ecr.<region>.amazonaws.com/ranikun/platform/core-trust-init
# When a repo is given the image is pushed and the digest read back from the registry is printed. Nothing is deployed here.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "build-images: $1" >&2; exit 1; }

: "${CORE_IMAGE:?CORE_IMAGE (digest reference) required}"
: "${CA_BUNDLE:?CA_BUNDLE (public PEM) required}"
: "${SOURCE_SHA:?SOURCE_SHA required}"
printf '%s' "$CORE_IMAGE" | grep -Eq '^[A-Za-z0-9._:/-]+@sha256:[0-9a-f]{64}$' \
  || fail "CORE_IMAGE must be repo@sha256:<64 hex> (tags are refused)"
printf '%s' "$SOURCE_SHA" | grep -Eq '^[0-9a-f]{7,40}$' || fail "SOURCE_SHA must be a git commit hash"
[ -s "$CA_BUNDLE" ] || fail "CA_BUNDLE is empty or missing"
grep -q 'PRIVATE KEY' "$CA_BUNDLE" && fail "CA_BUNDLE contains private key material; refusing"
# Every bundle certificate must be a self-signed root from make-root (pathlen:1) whose signature verifies with itself.
command -v openssl >/dev/null 2>&1 || fail "openssl is required on the build host to check CA_BUNDLE"
BCHK=$(mktemp -d)
trap 'rm -rf "$BCHK"' EXIT
awk -v d="$BCHK" '/BEGIN CERTIFICATE/ { n++; f = sprintf("%s/ca-%02d.pem", d, n) } f { print > f } /END CERTIFICATE/ { close(f); f = "" }' "$CA_BUNDLE"
nb=0
for c in "$BCHK"/ca-*.pem; do
  nb=$((nb + 1))
  s_sub=$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253) || fail "CA_BUNDLE certificate $nb does not parse"
  s_iss=$(openssl x509 -in "$c" -noout -issuer -nameopt RFC2253)
  [ "$(printf '%s' "$s_sub" | sed 's/^subject=//')" = "$(printf '%s' "$s_iss" | sed 's/^issuer=//')" ] \
    || fail "CA_BUNDLE certificate $nb is not self-issued (only roots from make-root may be bundled)"
  openssl verify -CAfile "$c" "$c" >/dev/null 2>&1 || fail "CA_BUNDLE certificate $nb does not verify with itself"
  openssl x509 -in "$c" -noout -ext basicConstraints | grep -q 'CA:TRUE, pathlen:1' \
    || fail "CA_BUNDLE certificate $nb must be CA:TRUE, pathlen:1"
done
[ "$nb" -ge 1 ] || fail "CA_BUNDLE holds no certificate"

TAG="$SOURCE_SHA"
echo "== front proxy image"
docker build --build-arg SOURCE_SHA="$SOURCE_SHA" -t "carelog-tls-proxy:$TAG" "$HERE/proxy"

CTX=$(mktemp -d)
trap 'rm -rf "$CTX"' EXIT
cp "$HERE/trust-init/Dockerfile" "$HERE/trust-init/trust-init.sh" "$CTX/"
cp "$CA_BUNDLE" "$CTX/ca-bundle.pem"
echo "== trust-init image (base: $CORE_IMAGE)"
docker build --build-arg CORE_IMAGE="$CORE_IMAGE" --build-arg CA_BUNDLE_SRC=ca-bundle.pem \
  --build-arg SOURCE_SHA="$SOURCE_SHA" -t "carelog-trust-init:$TAG" "$CTX"

if [ -n "${PROXY_REPO:-}" ]; then
  docker tag "carelog-tls-proxy:$TAG" "$PROXY_REPO:$TAG"
  docker push "$PROXY_REPO:$TAG" >/dev/null
  echo "front proxy digest: $(docker inspect -f '{{index .RepoDigests 0}}' "$PROXY_REPO:$TAG")"
fi
if [ -n "${TRUST_REPO:-}" ]; then
  docker tag "carelog-trust-init:$TAG" "$TRUST_REPO:$TAG"
  docker push "$TRUST_REPO:$TAG" >/dev/null
  echo "trust-init digest: $(docker inspect -f '{{index .RepoDigests 0}}' "$TRUST_REPO:$TAG")"
fi
echo "done (tags are for humans; Terraform takes the digests above)"
