#!/bin/sh
# Generates throwaway test PKI in $1 (must be empty or absent). Never used outside tests.
#   ca.crt / ca.key            self-signed test root (CA:TRUE, pathlen:1, as make-root produces)
#   good.crt / good.key        leaf, SAN DNS:$SAN, CA:FALSE, valid now
#   wrongsan.crt / .key        leaf, SAN DNS:other.test.internal (name mismatch case)
#   expired.crt / .key         leaf, SAN DNS:$SAN, notAfter in 2021 (expiry case)
#   bundle-good.json           {"tls_certificate","tls_private_key"} for good leaf
#   bundle-swapped.json        key and certificate swapped
#   ca-bundle.pem              CA certificate only (trust-init input)
#   leaf-as-ca-bundle.pem      a leaf certificate in the CA bundle (must be rejected)
set -eu
DIR="${1:?usage: gen-material.sh <dir>}"
SAN="carelog-dev.test.internal"
mkdir -p "$DIR/newcerts"
cd "$DIR"
: > index.txt
echo 1000 > serial

cat > ca.cnf <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = $DIR
database = $DIR/index.txt
new_certs_dir = $DIR/newcerts
serial = $DIR/serial
certificate = $DIR/ca.crt
private_key = $DIR/ca.key
default_md = sha256
policy = policy_any
unique_subject = no
copy_extensions = none
[ policy_any ]
commonName = supplied
EOF

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout ca.key -out ca.crt -days 3650 -subj "/CN=carelog-dev-test-ca" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:1" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

leaf() {  # name san startdate enddate
  name=$1; san=$2; start=$3; end=$4
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$name.key" -out "$name.csr" -subj "/CN=$san" 2>/dev/null
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" "subjectAltName=DNS:$san" > "$name.ext"
  openssl ca -batch -config ca.cnf -in "$name.csr" -out "$name.crt" \
    -extfile "$name.ext" -startdate "$start" -enddate "$end" -notext >/dev/null 2>&1
  rm -f "$name.csr" "$name.ext"
}

leaf good "$SAN" 20260101000000Z 20361231235959Z
leaf wrongsan other.test.internal 20260101000000Z 20361231235959Z
leaf expired "$SAN" 20200101000000Z 20210101000000Z

jq -n --rawfile c good.crt --rawfile k good.key '{tls_certificate: $c, tls_private_key: $k}' > bundle-good.json
jq -n --rawfile c good.key --rawfile k good.crt '{tls_certificate: $c, tls_private_key: $k}' > bundle-swapped.json
cp ca.crt ca-bundle.pem
cat ca.crt good.crt > leaf-as-ca-bundle.pem
chmod 600 ./*.key ./*.json

# Expired CA (trust-init must reject it). Self-signed with a past validity window.
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout expired-ca.key -out expired-ca.csr -subj "/CN=carelog-dev-expired-test-ca" 2>/dev/null
printf '%s\n' "basicConstraints=critical,CA:TRUE" "keyUsage=critical,keyCertSign,cRLSign" > expired-ca.ext
openssl ca -selfsign -batch -config ca.cnf -keyfile expired-ca.key -in expired-ca.csr -out expired-ca.crt \
  -extfile expired-ca.ext -startdate 20200101000000Z -enddate 20210101000000Z -notext >/dev/null 2>&1
rm -f expired-ca.csr expired-ca.ext
cp expired-ca.crt expired-ca-bundle.pem

# Two-tier material (test only). ca.crt plays the public root. Every name below is generated with openssl x509 -req.
NC_ISS="critical,permitted;DNS:.test.internal,permitted;DNS:$SAN,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0"
ec_key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1.key" 2>/dev/null; chmod 600 "$1.key"; }
sign() {  # name issuer-crt issuer-key subject-cn san-or-empty ext-lines(\n-separated)   -> $name.crt
  name=$1; ic=$2; ik=$3; cn=$4; san=$5; extra=$6
  ec_key "$name"
  openssl req -new -key "$name.key" -subj "/CN=$cn" -out "$name.csr" 2>/dev/null
  { printf '%s\n' "authorityKeyIdentifier=keyid" "subjectKeyIdentifier=hash"
    [ -n "$extra" ] && printf '%b\n' "$extra"
    [ -n "$san" ] && printf '%s\n' "subjectAltName=$san"; } > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA "$ic" -CAkey "$ik" -set_serial "0x$(openssl rand -hex 8)" -days 90 -sha256 \
    -extfile "$name.ext" -out "$name.crt" 2>/dev/null
  rm -f "$name.csr" "$name.ext"
}
sign inter ca.crt ca.key carelog-dev-issuing-ca "" \
  "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nnameConstraints=$NC_ISS"
sign good2 inter.crt inter.key "$SAN" "DNS:$SAN" \
  "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth"
sign evil2 inter.crt inter.key evil.example.org "DNS:evil.example.org" \
  "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth"
sign inter-pathlen1 ca.crt ca.key carelog-dev-issuing-ca "" \
  "basicConstraints=critical,CA:TRUE,pathlen:1\nkeyUsage=critical,keyCertSign,cRLSign\nnameConstraints=$NC_ISS"
sign inter-nonc ca.crt ca.key carelog-dev-issuing-ca "" \
  "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout alien-root.key -out alien-root.crt \
  -days 3650 -subj "/CN=carelog-alien-root" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
sign alien-inter alien-root.crt alien-root.key carelog-alien-issuing "" \
  "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nnameConstraints=$NC_ISS"

cat good2.crt inter.crt > chain-twotier.crt
jq -n --rawfile c chain-twotier.crt --rawfile k good2.key '{tls_certificate: $c, tls_private_key: $k}' > bundle-twotier.json
chmod 600 bundle-twotier.json
cat good2.crt inter.crt ca.crt > chain-three.crt
cat good2.crt inter-pathlen1.crt > chain-pathlen1.crt
cat good2.crt inter-nonc.crt > chain-nonc.crt
cat good2.crt alien-inter.crt > chain-alien.crt
cat evil2.crt inter.crt > chain-outside.crt
cat good2.crt inter.crt inter.key > chain-with-ca-key.crt

# Root-signed leaf (no issuing CA): the entrypoint must refuse it when an issuing CA is sent alongside.
sign rootleaf ca.crt ca.key "$SAN" "DNS:$SAN" \
  "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth"
cat rootleaf.crt inter.crt > chain-rootleaf.crt
# Self-signed root without pathlen (trust-init must refuse: pathlen 1 required).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout root-nopath.key -out root-nopath.crt \
  -days 3650 -subj "/CN=carelog-root-no-pathlen" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
cp root-nopath.crt root-nopath-bundle.pem
cp inter.crt inter-bundle.pem
