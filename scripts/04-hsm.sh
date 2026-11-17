#!/bin/sh
# Step 4: ML-DSA CA keys inside a (soft) HSM via PKCS#11 v3.2.
# SoftHSM2 built from main (ML-DSA is not in any release yet) + OpenSSL pkcs11-provider + OpenSC pkcs11-tool.
#   4.3/4.4  generate root + issuing CA keys INSIDE the token and run the CA from there (production pattern)
#   4.5      import the existing software root key from step 2 (migration pattern), prove it is the same key
# Key generation and signing: openssl + pkcs11-provider (standard PKCS#11, works with any HSM's PKCS#11 library).
# Key import: softhsm2-util (SoftHSM-specific). Inspection only: OpenSC pkcs11-tool.
set -u
CA=/lab/out/02
[ -f "$CA/root.key" ] || { echo "Run scripts/02-ca.sh first"; exit 1; }
OUT=/lab/out/04; rm -rf "$OUT"; mkdir -p "$OUT/tokens"; cd "$OUT"

M=/opt/softhsm/lib/softhsm/libsofthsm2.so
PIN=1234
export SOFTHSM2_CONF="$OUT/softhsm2.conf"
echo "directories.tokendir = $OUT/tokens" > "$SOFTHSM2_CONF"

RESULTS=""
result() { RESULTS="$RESULTS$(printf '%-62s %s' "$1" "$2")\n"; }
try() {  # try <label> <cmd...> : run, show last output lines, record OK/FAILED
  label=$1; shift
  if "$@" > try.log 2>&1; then result "$label" "OK"; else result "$label" "FAILED"; fi
  sed 's/^[0-9A-F]*:error:[0-9A-F]*:/error: /; s/^/  | /' try.log \
    | grep -vE "Using slot|self-signature (verify )?ok|^  \| subject=" | tail -3
}
p11() { pkcs11-tool --module $M "$@" 2>/dev/null; }

echo "== 4.0 Versions"
echo "  $(openssl version)"
pacman -Q pkcs11-provider opensc | sed 's/^/  /'
echo "  softhsm $(softhsm2-util --version), built from main @ $(cut -c1-10 /opt/softhsm/COMMIT)"

echo
echo "== 4.1 Initialise token; OpenSSL config that loads pkcs11-provider for this token"
softhsm2-util --init-token --free --label pqc-hsm-lab --pin $PIN --so-pin 5678 | sed 's/^/  /'
printf '%s' $PIN > pin.txt
cat > openssl-pkcs11.cnf <<EOF
openssl_conf = openssl_init
[openssl_init]
providers = provider_sect
[provider_sect]
default = default_sect
pkcs11  = pkcs11_sect
[default_sect]
activate = 1
[pkcs11_sect]
module = /usr/lib/ossl-modules/pkcs11.so
pkcs11-module-path = $M
pkcs11-module-token-pin = file:$OUT/pin.txt
# genpkey cannot write a non-extractable key to a file; write a PEM "pointer" (the PKCS#11 URI) instead
pkcs11-module-encode-provider-uri-to-pem = true
activate = 1
EOF
# From here on, every openssl command accepts pkcs11: URIs wherever it takes a key.
export OPENSSL_CONF="$OUT/openssl-pkcs11.cnf"

echo
echo "== 4.2 Token info and ML-DSA mechanisms (CKM_ML_DSA_KEY_PAIR_GEN 0x1c, CKM_ML_DSA 0x1d)"
p11 -I | sed 's/^/  /'
p11 -M > mechanisms.txt
echo "  total mechanisms: $(grep -c '^  ' mechanisms.txt)"
if grep -iE 'ML-DSA|mechtype-0x0*1[CDF]\b' mechanisms.txt; then
  result "ML-DSA mechanisms advertised by token" "YES"
else
  result "ML-DSA mechanisms advertised by token" "NO"
fi

echo
echo "== 4.3 Generate CA keys INSIDE the token (non-extractable), via pkcs11-provider"
try "Generate root CA key ML-DSA-87 in token" \
  openssl genpkey -propquery "?provider=pkcs11" -algorithm ML-DSA-87 \
    -pkeyopt "pkcs11_uri:pkcs11:token=pqc-hsm-lab;object=root-ca" -out root-ca.uri.pem
try "Generate issuing CA key ML-DSA-65 in token" \
  openssl genpkey -propquery "?provider=pkcs11" -algorithm ML-DSA-65 \
    -pkeyopt "pkcs11_uri:pkcs11:token=pqc-hsm-lab;object=issuing-ca" -out issuing-ca.uri.pem
echo "  root-ca.uri.pem is only a reference to the key, starting with: $(head -1 root-ca.uri.pem)"

ROOT="pkcs11:token=pqc-hsm-lab;object=root-ca;type=private"
ISSUING="pkcs11:token=pqc-hsm-lab;object=issuing-ca;type=private"

echo
echo "== 4.4 Two-tier CA with both CA keys in the token (same cert profiles as step 2)"
try "Root CA cert, self-signed by key in token" \
  openssl req -x509 -config "$CA/ca.cnf" -extensions v3_root -key "$ROOT" \
    -subj "/O=pqc-hsm-lab/CN=pqc-hsm-lab HSM Root CA" -days 3650 -out root.crt
try "Issuing CA CSR, signed by its key in token" \
  openssl req -new -config "$CA/ca.cnf" -key "$ISSUING" \
    -subj "/O=pqc-hsm-lab/CN=pqc-hsm-lab HSM Issuing CA" -out issuing.csr
try "Issuing CA cert, signed by root key in token" \
  openssl x509 -req -in issuing.csr -CA root.crt -CAkey "$ROOT" \
    -extfile "$CA/ca.cnf" -extensions v3_issuing -days 1825 -out issuing.crt
# The leaf key belongs to the TLS server, not the CA, so it stays a normal software key.
openssl genpkey -algorithm ML-DSA-44 -out leaf.key
openssl req -new -config "$CA/ca.cnf" -key leaf.key -subj "/O=pqc-hsm-lab/CN=localhost" -out leaf.csr
try "Leaf cert, signed by issuing CA key in token" \
  openssl x509 -req -in leaf.csr -CA issuing.crt -CAkey "$ISSUING" \
    -extfile "$CA/ca.cnf" -extensions v3_leaf -days 90 -out leaf.crt
try "Verify chain leaf -> HSM issuing -> HSM root" \
  openssl verify -show_chain -CAfile root.crt -untrusted issuing.crt leaf.crt

echo
echo "== 4.5 Migration path: import the step-2 software root key into the token"
try "Import step-2 root key (softhsm2-util --import)" \
  softhsm2-util --import "$CA/root.key" --token pqc-hsm-lab --label imported-root --id 99 --pin $PIN
openssl genpkey -algorithm ML-DSA-44 -out import-test.key
openssl req -new -key import-test.key -subj "/O=pqc-hsm-lab/CN=import test" -out import-test.csr
try "Issue a cert with the imported key in token" \
  openssl x509 -req -in import-test.csr -CA "$CA/root.crt" -CAkey "pkcs11:token=pqc-hsm-lab;object=imported-root;type=private" \
    -days 1 -out import-test.crt
try "Verify it against step-2 root.crt (same key, now in token)" \
  openssl verify -CAfile "$CA/root.crt" import-test.crt

echo
echo "== 4.6 Private keys in the token: generated vs imported"
p11 --login --pin $PIN -O --type privkey | grep -E 'Private Key Object|label|Access' | sed 's/^/  /'
echo "  -> generated keys: 'always sensitive, never extractable, local' = provably never left the token."
echo "     imported key:   only 'sensitive' = the token knows the key existed outside it before."

echo
echo "== Summary"
printf "$RESULTS" | sed 's/^/  /' | tee summary.txt
echo
echo "Done. Artefacts in out/04/"
