#!/bin/sh
# shellcheck disable=SC2086 # file names are generated without spaces; word splitting is intended
# Generates THROWAWAY CA, leaf and bundle material for the local tests. Never used outside tests.
# Runs inside the proxy image (openssl and jq). Usage: gen-material.sh <empty-output-dir>
set -eu
OUT="$1"
cd "$OUT"
NAME=ranikun-carelog-dev-api.dev.internal

cat > ca.cnf <<'CNF'
[ ca ]
default_ca = CA_default
[ CA_default ]
database = index.txt
new_certs_dir = .
serial = serial
default_md = sha256
policy = policy_any
unique_subject = no
[ policy_any ]
commonName = supplied
CNF
: > index.txt
echo 1000 > serial

printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n' > ca.ext
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s,DNS:carelog.test\n' "$NAME" > leaf.ext
printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:other.invalid\n' > wrongsan.ext

# CA 1 and CA 2 (valid, 30 days)
for ca in ca1 ca2; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -keyout $ca.key -out $ca.crt \
    -subj "/CN=throwaway $ca" -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
done
# Expired CA (self-signed, validity in 2020)
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout caexp.key -out caexp.csr -subj "/CN=throwaway expired CA" >/dev/null 2>&1
openssl ca -config ca.cnf -selfsign -batch -keyfile caexp.key -in caexp.csr -out caexp.crt -extfile ca.ext \
  -startdate 20200101000000Z -enddate 20200201000000Z -md sha256 -notext >/dev/null 2>&1

leaf() { # name signing-ca-name ext-file
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout $1.key -out $1.csr -subj "/CN=$NAME" >/dev/null 2>&1
  openssl x509 -req -in $1.csr -CA $2.crt -CAkey $2.key -CAcreateserial -days 20 -extfile $3 -out $1.crt >/dev/null 2>&1
}
leaf leaf1 ca1 leaf.ext
leaf leaf2 ca2 leaf.ext
leaf wrongsan ca1 wrongsan.ext
# Expired leaf: signed by ca1 with a 2020 validity window
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout leafexp.key -out leafexp.csr -subj "/CN=$NAME" >/dev/null 2>&1
openssl ca -config ca.cnf -batch -cert ca1.crt -keyfile ca1.key -in leafexp.csr -out leafexp.crt -extfile leaf.ext \
  -startdate 20200101000000Z -enddate 20200201000000Z -md sha256 -notext >/dev/null 2>&1
# Unrelated key pair with the expected name (for the mismatch cases)
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout other.key -out other.csr -subj "/CN=other" >/dev/null 2>&1

# Bundles for the proxy (1-secret JSON shape, built with jq so PEM newlines are JSON-escaped)
J() { jq -c -n --rawfile c "$1" --rawfile k "$2" '{tls_certificate: $c, tls_private_key: $k}' > "$3"; }
J leaf1.crt leaf1.key bundle-ok.json
J leaf2.crt leaf2.key bundle-ok2.json
J leaf1.crt other.key bundle-mismatch.json
J leafexp.crt leafexp.key bundle-expired.json
J wrongsan.crt wrongsan.key bundle-wrongsan.json
J ca1.crt ca1.key bundle-swap-ca.json
J leaf1.crt leaf1.crt bundle-key-field-cert.json
J leaf1.key leaf1.crt bundle-fields-swapped.json
J leaf1.crt leaf1.crt bundle-no-key.json
jq -c -n --rawfile c leaf1.crt '{tls_certificate: $c}' > bundle-nokey.json
cat leaf1.crt ca1.crt > chain.pem
J chain.pem leaf1.key bundle-chain.json
printf 'not a certificate\n' > garbage.pem
J garbage.pem leaf1.key bundle-garbage-cert.json
printf 'this is not json\n' > bundle-not-json.txt

# CA bundles for trust-init (public CA certificates only)
cp ca1.crt ca-bundle-1.pem
cat ca1.crt ca2.crt > ca-bundle-2.pem
cp leaf1.crt ca-bundle-leaf.pem
cp caexp.crt ca-bundle-expired.pem
cat ca1.crt ca1.key > ca-bundle-key.pem
printf 'hello world\n' > ca-bundle-text.pem
: > ca-bundle-empty.pem
awk 'NR==3{print "junk line"} {print}' ca1.crt > ca-bundle-nonpem.pem
# Leaves with other SAN shapes (all signed by CA 1). Arguments: name, SAN list as openssl writes it.
mksan() {
  printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' "$2" > "$1.ext"
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$1.key" -out "$1.csr" -subj "/CN=san-test" >/dev/null 2>&1
  openssl x509 -req -in "$1.csr" -CA ca1.crt -CAkey ca1.key -CAcreateserial -days 20 -extfile "$1.ext" -out "$1.crt" >/dev/null 2>&1
  jq -c -n --rawfile c "$1.crt" --rawfile k "$1.key" '{tls_certificate: $c, tls_private_key: $k}' > "bundle-$1.json"
}
mksan san-prefix "DNS:x.$NAME"
mksan san-suffix "DNS:$NAME.evil"
mksan san-wild "DNS:*.dev.internal"
mksan san-case "DNS:RANIKUN-CARELOG-DEV-API.DEV.INTERNAL"
mksan san-dot "DNS:$NAME."
mksan san-iponly "IP:10.0.0.1"
mksan san-list "DNS:carelog.test,IP:10.0.0.1,DNS:$NAME"
echo "material ready"
