#!/bin/sh
# Step 5 (optional): composite ML-DSA certificates (IETF LAMPS, published as RFC 10073 in Nov 2026).
# One key = ML-DSA + classical key; one signature = both signatures; valid only if BOTH verify.
# Tooling today: Bouncy Castle 1.86 (Java) implements it; OpenSSL (3.5 and 4.1) does not.
set -eu
OUT=/lab/out/05; rm -rf "$OUT"; mkdir -p "$OUT"; cd /lab

echo "== 5.1 Generate composite self-signed CA certs with Bouncy Castle $(ls /opt/bc | sed -n 's/bcprov-jdk18on-\(.*\)\.jar/\1/p')"
java -cp '/opt/bc/*' scripts/Composite.java "$OUT" \
  MLDSA44-ECDSA-P256-SHA256 MLDSA65-ECDSA-P256-SHA512 MLDSA87-ECDSA-P384-SHA512 \
  | tee "$OUT/sizes.txt"

C="$OUT/MLDSA65-ECDSA-P256-SHA512.crt"
echo
echo "== 5.2 Same cert through OpenSSL $(openssl version | cut -d' ' -f2): parse"
openssl x509 -in "$C" -noout -text 2>&1 | grep -E "Signature Algorithm|Public Key Algorithm|Unable" | sort -u | sed 's/^ */  /'

echo
echo "== 5.3 OpenSSL: verify"
if openssl verify -CAfile "$C" "$C" > "$OUT/openssl-verify.log" 2>&1; then
  echo "  OpenSSL verify: OK"
else
  grep -vE "^[0-9A-F]+:error" "$OUT/openssl-verify.log" | sed 's/^/  /'
  echo "  => OpenSSL cannot decode the composite public key (unknown OID), so it cannot verify the cert."
fi

echo
echo "Done. Artefacts in out/05/"
