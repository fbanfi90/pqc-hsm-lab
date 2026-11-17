#!/bin/sh
# Step 3: TLS 1.3 with the ML-DSA chain from step 2 + X25519MLKEM768 hybrid key exchange,
# and what happens with classical-only clients.
set -eu
CA=/lab/out/02
[ -f "$CA/fullchain.pem" ] || { echo "Run scripts/02-ca.sh first"; exit 1; }
OUT=/lab/out/03; rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

SRV_PID=""
server() {  # server <port> <extra s_server args...>
  port=$1; shift
  openssl s_server -accept "$port" -tls1_3 -www -quiet \
    -cert "$CA/leaf.crt" -key "$CA/leaf.key" -cert_chain "$CA/issuing.crt" "$@" > "server-$port.log" 2>&1 &
  SRV_PID=$!; sleep 1
}
stop() { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
trap stop EXIT
client() {  # client <port> <label> <extra s_client args...>
  port=$1; label=$2; shift 2
  echo "--- client: $label"
  log="client-$port-$(echo "$label" | tr -c 'a-zA-Z0-9' '_').log"
  openssl s_client -connect "localhost:$port" -servername localhost -verify_return_error "$@" \
    < /dev/null > "$log" 2>&1 && rc=0 || rc=$?
  if [ $rc -eq 0 ]; then
    grep -hE "Negotiated TLS1.3 group|Peer Temp Key|Peer signature type|^Verify return code|handshake has read" "$log" | sed 's/^/  /'
  else
    grep -hE "alert|handshake has read" "$log" | sed 's/^[0-9A-F]*:error:[0-9A-F]*:/error: /; s/^/  /'
  fi
  [ $rc -eq 0 ] && echo "  => handshake OK" || echo "  => handshake FAILED (exit $rc)"
}

echo "== 3.1 PQ-only server: ML-DSA cert, key exchange X25519MLKEM768 only"
server 4431 -groups X25519MLKEM768
client 4431 "PQ client (OpenSSL defaults)"             -CAfile "$CA/root.crt"
client 4431 "classical KEX client (X25519 only)"           -CAfile "$CA/root.crt" -groups X25519:P-256
client 4431 "classical sigalgs client (no ML-DSA)"         -CAfile "$CA/root.crt" \
       -sigalgs "ECDSA+SHA256:RSA-PSS+SHA256:rsa_pkcs1_sha256:ed25519"
stop

echo
echo "== 3.2 Transitional server: same ML-DSA cert, groups X25519MLKEM768 preferred, X25519 allowed"
server 4432 -groups X25519MLKEM768:X25519
client 4432 "classical KEX client (X25519 only)"           -CAfile "$CA/root.crt" -groups X25519
stop

echo
echo "== 3.3 Dual-certificate server: ML-DSA chain + classical ECDSA P-256 cert on the same port"
openssl req -x509 -newkey EC -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout ecdsa.key -out ecdsa.crt \
  -subj "/O=pqc-hsm-lab/CN=localhost" -addext "subjectAltName=DNS:localhost" -days 90 2>/dev/null
server 4433 -groups X25519MLKEM768:X25519 -dcert ecdsa.crt -dkey ecdsa.key
client 4433 "PQ client"                                    -CAfile "$CA/root.crt"
client 4433 "classical client (X25519, ECDSA only)"        -CAfile ecdsa.crt -groups X25519 \
       -sigalgs "ECDSA+SHA256:RSA-PSS+SHA256"
stop

echo
echo "Done. Full client/server logs in out/03/"
