#!/bin/sh
# Step 2: two-tier PKI fully on ML-DSA.
#   Root CA     ML-DSA-87 (offline, long-lived -> strongest parameter set)
#   Issuing CA  ML-DSA-65 (online, medium-lived)
#   Leaf (TLS)  ML-DSA-44 (short-lived, sent in every handshake -> smallest)
set -eu
OUT=/lab/out/02; rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

cat > ca.cnf <<'EOF'
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = placeholder

[v3_root]
basicConstraints     = critical, CA:true
keyUsage             = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash

[v3_issuing]
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, keyCertSign, cRLSign
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always

[v3_leaf]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = serverAuth
subjectAltName         = DNS:localhost, IP:127.0.0.1
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
EOF

echo "== 2.1 Root CA (ML-DSA-87, self-signed, 10 years)"
openssl genpkey -algorithm ML-DSA-87 -out root.key
openssl req -x509 -config ca.cnf -extensions v3_root -key root.key \
  -subj "/O=pqc-hsm-lab/CN=pqc-hsm-lab Root CA" -days 3650 -out root.crt

echo "== 2.2 Issuing CA (ML-DSA-65, signed by root, 5 years)"
openssl genpkey -algorithm ML-DSA-65 -out issuing.key
openssl req -new -config ca.cnf -key issuing.key -subj "/O=pqc-hsm-lab/CN=pqc-hsm-lab Issuing CA" -out issuing.csr
openssl req -verify -in issuing.csr -noout          # proof-of-possession: CSR self-signature with ML-DSA
openssl x509 -req -in issuing.csr -CA root.crt -CAkey root.key \
  -extfile ca.cnf -extensions v3_issuing -days 1825 -out issuing.crt

echo "== 2.3 Leaf / TLS server cert (ML-DSA-44, signed by issuing CA, 90 days)"
openssl genpkey -algorithm ML-DSA-44 -out leaf.key
openssl req -new -config ca.cnf -key leaf.key -subj "/O=pqc-hsm-lab/CN=localhost" -out leaf.csr
openssl req -verify -in leaf.csr -noout
openssl x509 -req -in leaf.csr -CA issuing.crt -CAkey issuing.key \
  -extfile ca.cnf -extensions v3_leaf -days 90 -out leaf.crt

cat leaf.crt issuing.crt > fullchain.pem   # what a TLS server sends (root stays in the client trust store)

echo
echo "== 2.4 Verify chain"
openssl verify -show_chain -CAfile root.crt -untrusted issuing.crt leaf.crt

echo
echo "== 2.5 Algorithms per cert (public key / signature)"
for c in root issuing leaf; do
  pk=$(openssl x509 -in $c.crt -noout -text | awk -F': ' '/Public Key Algorithm/{print $2; exit}')
  sa=$(openssl x509 -in $c.crt -noout -text | awk -F': ' '/Signature Algorithm/{print $2; exit}')
  printf '%-8s key=%-10s signed-with=%s\n' "$c" "$pk" "$sa"
done

echo
echo "== 2.6 Sizes in bytes (DER)"
for c in root issuing leaf; do
  printf '%-8s %6s\n' "$c" "$(openssl x509 -in $c.crt -outform DER | wc -c)"
done | tee sizes.txt
chain=$(( $(openssl x509 -in leaf.crt -outform DER | wc -c) + $(openssl x509 -in issuing.crt -outform DER | wc -c) ))
echo "TLS chain on the wire (leaf + issuing): $chain bytes" | tee -a sizes.txt

echo
echo "Done. Artefacts in out/02/"
