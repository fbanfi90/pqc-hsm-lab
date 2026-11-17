#!/bin/sh
# Speed comparison: OpenSSL 4.1 (lab image) vs OpenSSL 3.5 (Debian trixie baseline image), same host.
# Runs on the HOST, not in the container: it starts both containers itself.
#   usage: scripts/bench.sh [runs]     (default 5; each run takes about 2 minutes)
#          scripts/bench.sh --summary  (only rebuild summary.txt from the existing raw output)
# Runs alternate between the two images so that turbo/thermal drift affects both equally.
# Output: out/bench/{lab,baseline}-runN.txt (raw `openssl speed`) and out/bench/summary.txt (median and min-max per op).
set -eu
cd "$(dirname "$0")/.."
OUT=out/bench
if [ "${1:-}" = "--summary" ]; then
  RUNS=0
else
  RUNS=${1:-5}
  rm -rf "$OUT"; mkdir -p "$OUT"
fi

SPEED='openssl version; openssl speed -seconds 3 ML-DSA-44 ML-DSA-65 ML-DSA-87 ecdsap256 rsa3072 2>/dev/null'

if [ "$RUNS" -gt 0 ]; then
  docker compose build -q pqc-hsm-lab
  docker compose --profile baseline build -q baseline
fi

i=1
while [ "$i" -le "$RUNS" ]; do
  echo "run $i/$RUNS"
  docker compose run --rm pqc-hsm-lab sh -c "$SPEED" > "$OUT/lab-run$i.txt"
  docker compose --profile baseline run --rm baseline sh -c "$SPEED" > "$OUT/baseline-run$i.txt"
  i=$((i + 1))
done

# Summarise: min-max ops/s per image, algorithm and operation.
# ECDSA comes from the legacy EC table (no keygen); RSA and ML-DSA from the generic signature table.
awk '
  FNR == 1 { img = (FILENAME ~ /\/lab-/) ? "lab" : "baseline"; tbl = ""; ver[img] = $2 }
  /keygens\/s/ { tbl = (/sign\/s/) ? "sig" : "kem"; next }
  /prime256v1|nistp256/ { put("ECDSA-P256", "sign", $(NF-1)); put("ECDSA-P256", "verify", $NF); next }
  tbl == "sig" && $1 ~ /^(rsa3072|ML-DSA-(44|65|87))$/ {
    a = ($1 == "rsa3072") ? "RSA-3072" : $1
    put(a, "keygen", $(NF-2)); put(a, "sign", $(NF-1)); put(a, "verify", $NF)
  }
  function put(a, op, v,   k) {
    k = img SUBSEP a SUBSEP op
    n[k]++; val[k, n[k]] = v + 0
  }
  function stats(k,   i, j, t, c, m) {   # sets LO, MED, HI for key k (insertion sort; n is small)
    c = n[k]
    for (i = 1; i <= c; i++) s[i] = val[k, i]
    for (i = 2; i <= c; i++) { t = s[i]; for (j = i - 1; j >= 1 && s[j] > t; j--) s[j + 1] = s[j]; s[j + 1] = t }
    LO = s[1]; HI = s[c]; m = int((c + 1) / 2)
    MED = (c % 2) ? s[m] : (s[m] + s[m + 1]) / 2
  }
  function fmt(v) { return (v >= 1000) ? sprintf("%.1fk", v / 1000) : (v < 100) ? sprintf("%.1f", v) : sprintf("%d", v + 0.5) }
  function cell(img, a, op,   k) {
    k = img SUBSEP a SUBSEP op
    if (!(k in n)) return "-"
    stats(k)
    return fmt(MED) " (" fmt(LO) "-" fmt(HI) ")"
  }
  END {
    printf "ops/s, single thread: median (min-max) over the runs. lab = OpenSSL %s, baseline = OpenSSL %s\n\n", ver["lab"], ver["baseline"]
    printf "%-11s | %-21s %-21s %-21s | %-21s %-21s %-21s\n", "", "lab keygen", "lab sign", "lab verify", "base keygen", "base sign", "base verify"
    na = split("ECDSA-P256 RSA-3072 ML-DSA-44 ML-DSA-65 ML-DSA-87", algs, " ")
    for (j = 1; j <= na; j++) {
      a = algs[j]
      printf "%-11s | %-21s %-21s %-21s | %-21s %-21s %-21s\n", a,
        cell("lab", a, "keygen"), cell("lab", a, "sign"), cell("lab", a, "verify"),
        cell("baseline", a, "keygen"), cell("baseline", a, "sign"), cell("baseline", a, "verify")
    }
  }
' "$OUT"/lab-run*.txt "$OUT"/baseline-run*.txt | tee "$OUT/summary.txt"

echo
echo "Done. Raw output and summary in out/bench/"
