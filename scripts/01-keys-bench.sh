#!/bin/sh
# Step 1: ML-DSA-44/65/87 vs ECDSA P-256 vs RSA-3072 — key, signature, cert sizes and speed.
set -eu
OUT=/lab/out/01; rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

echo "== $(openssl version)"
echo "hello post-quantum PKI" > msg.txt

echo
echo "== 1.1 Sizes in bytes (DER). priv = OpenSSL default encoding; seed = ML-DSA 32-byte seed-only form"
printf '%-10s %8s %8s %8s %8s %8s\n' alg pub priv seed sig cert
for alg in ML-DSA-44 ML-DSA-65 ML-DSA-87 EC-P256 RSA-3072; do
  case $alg in
    EC-P256)  set -- -algorithm EC  -pkeyopt ec_paramgen_curve:P-256; dig="-digest sha256" ;;
    RSA-3072) set -- -algorithm RSA -pkeyopt rsa_keygen_bits:3072;    dig="-digest sha256" ;;
    *)        set -- -algorithm "$alg";                               dig="" ;;  # ML-DSA signs the raw message ("pure" mode)
  esac
  openssl genpkey -quiet "$@" -out "$alg.key"
  openssl pkey -in "$alg.key" -pubout -outform DER -out "$alg.pub.der"
  openssl pkey -in "$alg.key" -outform DER -out "$alg.key.der"
  seed=-
  case $alg in ML-DSA-*)
    openssl pkey -in "$alg.key" -outform DER -provparam ml-dsa.output_formats=seed-only -out "$alg.seed.der"
    seed=$(wc -c < "$alg.seed.der") ;;
  esac
  # shellcheck disable=SC2086
  openssl pkeyutl -sign   -rawin $dig -inkey "$alg.key" -in msg.txt -out "$alg.sig"
  # shellcheck disable=SC2086
  openssl pkeyutl -verify -rawin $dig -inkey "$alg.key" -in msg.txt -sigfile "$alg.sig" > /dev/null
  openssl req -x509 -key "$alg.key" -subj "/CN=bench $alg" -days 1 -outform DER -out "$alg.crt.der"
  printf '%-10s %8s %8s %8s %8s %8s\n' "$alg" "$(wc -c < "$alg.pub.der")" "$(wc -c < "$alg.key.der")" \
    "$seed" "$(wc -c < "$alg.sig")" "$(wc -c < "$alg.crt.der")"
done | tee sizes.txt

echo
echo "== 1.2 Speed: openssl speed, 3 s per operation, single thread (laptop CPU: compare orders of magnitude, not exact values)"
openssl speed -seconds 3 ML-DSA-44 ML-DSA-65 ML-DSA-87 ecdsap256 rsa3072 2>/dev/null \
  | awk '/encaps/{skip=1; next} skip{skip=0; next} /sign *verify/{on=1} on' | tee speed.txt

echo
echo "Done. Artefacts in out/01/"
