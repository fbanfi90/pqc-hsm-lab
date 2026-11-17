# Results: ML-DSA PKI migration

Results of the five lab steps. Each section describes what the step does, then its results, their limitations and what they imply for a production migration, and finally the files it writes. How to run the lab is in the [README](README.md).

- [Test environment](#test-environment)
- [Step 1: sizes and speed](#step-1-sizes-and-speed)
- [Step 2: two-tier CA on ML-DSA](#step-2-two-tier-ca-on-ml-dsa)
- [Step 3: TLS 1.3 with ML-DSA and X25519MLKEM768](#step-3-tls-13-with-ml-dsa-and-x25519mlkem768)
- [Step 4: ML-DSA CA keys in an HSM (PKCS#11 v3.2)](#step-4-ml-dsa-ca-keys-in-an-hsm-pkcs11-v32)
- [Step 5: composite certificates](#step-5-composite-certificates)
- [Overall readiness](#overall-readiness)
- [References](#references)

## Test environment

Measured 2026-11-17 from a clean `docker compose build --no-cache`.

| | |
|---|---|
| Host | Lenovo ThinkPad X1 Nano, Intel Core i7-1260P (4 P-cores + 8 E-cores, up to 4.7 GHz), 16 GB RAM |
| OS | Arch Linux, bare metal, kernel 7.3.4; `balanced` power profile, on AC power |
| Container runtime | Docker 29.9.3, Compose 5.7.1 |
| Lab image | OpenSSL 4.1.0; SoftHSM2 `main` @ `7b9b2557`; pkcs11-provider 1.3.0; OpenSC 0.27.1; OpenJDK 21.0.13 + Bouncy Castle 1.86 |
| Baseline | Debian 13 (trixie) stable packages: OpenSSL 3.5.7, SoftHSM2 2.6.1, pkcs11-provider 1.0, OpenSC 0.26.1 |

The **baseline** shows what a current stable enterprise distribution provides out of the box. It was measured on the same host and is reported wherever it differs from the lab image. For speed, it is the `baseline` image ([Dockerfile.baseline](Dockerfile.baseline)) used by `make bench`. The PKCS#11 package versions were checked in a plain `debian:trixie` container.

---

## Step 1: sizes and speed

**Script:** [`scripts/01-keys-bench.sh`](scripts/01-keys-bench.sh), plus [`scripts/bench.sh`](scripts/bench.sh) for the repeated speed comparison · **Output:** `out/01/`, `out/bench/`

Creates a throwaway key for each of ML-DSA-44, ML-DSA-65, ML-DSA-87, ECDSA P-256 and RSA-3072. Each key signs a short message and produces a minimal self-signed certificate. The step then measures every artefact and runs `openssl speed` once. It quantifies the size and performance impact before any real system is touched. Nothing from this step is reused later.

A single speed run on a laptop is noisy. `make bench` ([`scripts/bench.sh`](scripts/bench.sh)) therefore repeats the same `openssl speed` command several times, alternating between the lab image (OpenSSL 4.1) and the baseline image (OpenSSL 3.5), and reports the median and min–max per operation.

### Results

Sizes are in bytes:
- `pub`: the SubjectPublicKeyInfo DER
- `priv`: OpenSSL's default PKCS#8 encoding
- `seed`: the seed-only PKCS#8 form
- `sig`: a raw signature
- `cert`: a minimal self-signed DER certificate

| alg | pub | priv | seed | sig | cert |
|---|---:|---:|---:|---:|---:|
| ML-DSA-44 | 1,334 | 2,626 | 54 | 2,420 | 3,960 |
| ML-DSA-65 | 1,974 | 4,098 | 54 | 3,309 | 5,489 |
| ML-DSA-87 | 2,614 | 4,962 | 54 | 4,627 | 7,447 |
| ECDSA P-256 | 91 | 138 | – | ~71 | ~360 |
| RSA-3072 | 422 | ~1,792 | – | 384 | 1,014 |

Speed is in operations per second, single thread. Each cell is the median of five runs of `openssl speed -seconds 3`, taken with `make bench`, alternating between the two images.

<table>
  <thead>
    <tr>
      <th rowspan="2" align="left">Algorithm</th>
      <th colspan="3">OpenSSL 4.1 (lab image)</th>
      <th colspan="3">OpenSSL 3.5 (Debian trixie)</th>
    </tr>
    <tr>
      <th align="right">keygen/s</th><th align="right">sign/s</th><th align="right">verify/s</th>
      <th align="right">keygen/s</th><th align="right">sign/s</th><th align="right">verify/s</th>
    </tr>
  </thead>
  <tbody>
    <tr><td>ECDSA P-256</td><td align="right">–</td><td align="right">48.6k</td><td align="right">14.9k</td><td align="right">–</td><td align="right">46.2k</td><td align="right">14.8k</td></tr>
    <tr><td>RSA-3072</td><td align="right">6.1</td><td align="right">577</td><td align="right">26.5k</td><td align="right">6.2</td><td align="right">571</td><td align="right">27.6k</td></tr>
    <tr><td>ML-DSA-44</td><td align="right">17.8k</td><td align="right">6.4k</td><td align="right">23.2k</td><td align="right">10.8k</td><td align="right">2.0k</td><td align="right">10.1k</td></tr>
    <tr><td>ML-DSA-65</td><td align="right">8.9k</td><td align="right">4.0k</td><td align="right">13.9k</td><td align="right">5.9k</td><td align="right">1.2k</td><td align="right">6.5k</td></tr>
    <tr><td>ML-DSA-87</td><td align="right">6.8k</td><td align="right">3.3k</td><td align="right">8.0k</td><td align="right">4.2k</td><td align="right">1.1k</td><td align="right">3.9k</td></tr>
  </tbody>
</table>

ECDSA has no keygen figure because `openssl speed` reports it only in the legacy EC table, which has no keygen column. `make bench` also prints the min–max range of each cell (`out/bench/summary.txt`).

### Observations

- **Size.** ML-DSA-65 compared with P-256: the public key is about 22× larger, the signature about 47× larger and a certificate about 15× larger. Against RSA-3072, the closer classical comparison, ML-DSA signatures are still 6–12× larger.
- **Two private-key forms.** By default OpenSSL stores *seed + expanded key* (4 KB for ML-DSA-65). The 32-byte seed alone (54 B as PKCS#8) can regenerate everything. The seed-only form is selected with `-provparam ml-dsa.output_formats=seed-only`.
- **Performance depends heavily on the implementation.** OpenSSL 4.1.0 added x86_64-optimised ML-DSA (per its NEWS). On the same CPU, 4.1 signs about 3× faster than 3.5, verifies about 2× faster and generates keys about 1.5× faster. Classical algorithms perform the same on both versions.
- **ML-DSA compared with classical algorithms, on 4.1:**
  - **Verify:** ML-DSA-44 is about 1.5× faster than ECDSA P-256 (23k/s vs 15k/s), ML-DSA-65 is on par, and ML-DSA-87 is about half as fast.
  - **Sign:** 8–15× slower than ECDSA, but 6–11× faster than RSA-3072.
  - **Key generation:** roughly 1,000–3,000× faster than RSA-3072.
- ML-DSA signing uses rejection sampling, so its time per signature varies. FIPS 204 gives the expected loop counts as 4.25 (ML-DSA-44), 5.1 (ML-DSA-65) and 3.85 (ML-DSA-87).

### Limitations

- **Laptop CPU.** In both series, the first run was 20–25% faster than the following four. That is turbo boost before sustained power and thermal limits apply. Some runs also show a single dip, such as one ECDSA verify run at 9.2k/s against about 15k/s for the others, most likely from background load. That is why the table reports medians, not means or ranges. The i7-1260P also mixes P- and E-cores, and the benchmark was not pinned to a core type. Compare magnitudes, not exact values.
- HSMs perform very differently, so CA or HSM throughput can't be sized from these numbers.
- Only "pure" ML-DSA was measured, not HashML-DSA (pre-hash). RFC 9881 uses pure ML-DSA for X.509.

### Migration implications

- **Size is the real cost, not CPU.** Every system that stores or moves keys, signatures or certificates needs checking:
  - database column widths and LDAP attributes
  - HSM object limits, and smart-card and TPM storage
  - CRL and OCSP response sizes
  - protocol length fields
  - log pipelines that truncate PEM
- **Library version matters for performance.** OpenSSL 3.5 and 4.1 differ by 2–3× in ML-DSA speed on the same hardware. Benchmark on the stack you will actually deploy.
- **Choose a private-key format deliberately.** Seed-only is small and canonical, which suits backup and escrow. Expanded keys avoid recomputation. Implementations disagree on which forms they accept, so test export and import between tools before depending on it.
- **Crypto agility** means algorithm, key size and parameter set are configuration, not code. Here, three ML-DSA levels and two classical algorithms all ran through the same `genpkey`/`req`/`pkeyutl` calls, on two OpenSSL major versions, without script changes.

### Output files

`out/01/`, per algorithm (`<alg>` = `ML-DSA-65`, `EC-P256`, …):

| File | Content |
|---|---|
| `<alg>.key` | Private key, PEM |
| `<alg>.key.der` | Same private key in DER, for size measurement |
| `<alg>.seed.der` | ML-DSA only: the private key as the 32-byte seed alone, from which the full key can be regenerated |
| `<alg>.pub.der` | Public key, DER |
| `<alg>.sig` | Signature over `msg.txt` |
| `<alg>.crt.der` | Minimal self-signed certificate |

`out/01/sizes.txt` holds the size table and `out/01/speed.txt` the single `openssl speed` run. `out/bench/` holds the raw output of every `make bench` run (`lab-runN.txt`, `baseline-runN.txt`) and the median/min–max table (`summary.txt`).

Reading raw `openssl speed` output:
- It prints three tables: the legacy RSA table, the legacy EC table, and a newer generic signature table that includes keygen. ML-DSA appears only in the generic table, and ECDSA only in its legacy table. The table above takes RSA and ML-DSA from the generic table and ECDSA from the legacy one.
- In each table, the left columns are seconds per operation and the `/s` columns are operations per second.

---

## Step 2: two-tier CA on ML-DSA

**Script:** [`scripts/02-ca.sh`](scripts/02-ca.sh) · **Output:** `out/02/`

Builds a complete certificate hierarchy on ML-DSA, with keys as ordinary software files, and verifies the chain:
- **root CA** (ML-DSA-87), which signs
- **issuing CA** (ML-DSA-65), which signs
- a **TLS server certificate** for `localhost` (ML-DSA-44)

44/65/87 are not key sizes. They name ML-DSA parameter sets targeting NIST security categories 2, 3 and 5 (roughly comparable to P-256, P-384 and P-521).

### Results

The chain was built with stock OpenSSL commands (`genpkey`, `req`, `x509 -req`). CSR proof-of-possession and `openssl verify -show_chain` passed on both OpenSSL 3.5 and 4.1, with identical certificate sizes.

| cert | public key | signed with | DER size |
|---|---|---|---:|
| root | ML-DSA-87 | ML-DSA-87 | 7,515 |
| issuing | ML-DSA-65 | ML-DSA-87 | 6,914 |
| leaf | ML-DSA-44 | ML-DSA-65 | 4,991 |
| **TLS chain (leaf + issuing)** | | | **11,905** |

An equivalent ECDSA P-256 chain is about 0.8 KB.

### Parameter choice

- Mixing levels follows the classical pattern, such as an RSA-4096 root with RSA-2048 leaves. It is a design choice, not a mandated practice.
- The root uses the strongest level because it lives longest and is the hardest to replace.
- The leaf uses ML-DSA-44 because it is sent in every handshake.
- Each certificate carries **its issuer's** signature. The root's parameter set therefore appears in every handshake, through the issuing CA certificate: 4,627 B of ML-DSA-87 signature.
- CNSA 2.0 (US national security systems) requires ML-DSA-87 throughout. That brings the chain to about 15 KB.

### Limitations

- This is a minimal CA built from `x509 -req`. It has no CRL or OCSP, no policy OIDs and no name constraints. Revocation artefacts grow too: every CRL and OCSP response carries an ML-DSA signature of 2.4–4.6 KB.
- Only OpenSSL validated the chain. Not tested: Windows CryptoAPI, Java PKIX, Go `crypto/x509`, browsers, and embedded TLS stacks such as mbedTLS or wolfSSL.

### Migration implications

- **Building an ML-DSA CA is easy. Getting its root trusted is the slow part.** A new PQ root must reach every relying party's trust store. In a private PKI that is a deployment project measured in months to years, so plan the root rollout first.
- **A parallel PQ hierarchy** next to the classical one (dual certificates, see step 3.3) gives the best backward compatibility. The cost is double issuance, revocation and monitoring.
- **Lifetimes:** a root created now should remain secure once a cryptographically relevant quantum computer exists. That argues for ML-DSA-87 at the root even when leaves use ML-DSA-44.

### Output files

| File | Content |
|---|---|
| `ca.cnf` | OpenSSL extension profiles per tier (reused by step 4). Root may sign CAs, the issuing CA only end-entity certs (`pathlen:0`), the leaf is a TLS server cert with SAN `localhost` |
| `root.key`, `root.crt` | Root CA key and self-signed certificate (trust anchor) |
| `issuing.key`, `issuing.csr`, `issuing.crt` | Issuing CA key, CSR, and certificate signed by the root |
| `leaf.key`, `leaf.csr`, `leaf.crt` | Server key, CSR, and certificate signed by the issuing CA |
| `fullchain.pem` | Leaf + issuing CA, which is what a TLS server sends. The root is omitted because clients already trust it |
| `sizes.txt` | Certificate sizes and on-the-wire chain size |

---

## Step 3: TLS 1.3 with ML-DSA and X25519MLKEM768

**Script:** [`scripts/03-tls.sh`](scripts/03-tls.sh) · **Output:** `out/03/` · **Requires:** step 2

Runs `openssl s_server` instances with step 2's certificates and connects `openssl s_client` with different capabilities. It answers whether PQ TLS works and what happens to clients that only support classical algorithms.

| Port | Server configuration |
|---|---|
| 4431 | PQ-only: accepts only the X25519MLKEM768 hybrid key exchange. One PQ client and two kinds of classical client connect |
| 4432 | Transitional: prefers hybrid key exchange, also accepts X25519 |
| 4433 | Dual certificate: holds both the ML-DSA chain and an ECDSA certificate |

### Results

These are the OpenSSL 4.1 results. 3.5 gave the same outcomes, with a ClientHello 26–32 B smaller.

| scenario | client offers | outcome | bytes read / written by client |
|---|---|---|---:|
| 3.1 PQ-only server | defaults (X25519MLKEM768, ML-DSA) | OK; group X25519MLKEM768, sig mldsa44 | 15,718 / 1,663 |
| 3.1 PQ-only server | groups X25519:P-256 | **alert 40 handshake_failure** | 7 / 345 |
| 3.1 PQ-only server | sigalgs without ML-DSA | **alert 40 handshake_failure** | 7 / 1,513 |
| 3.2 transitional server | groups X25519 | OK; X25519, sig mldsa44 | 14,640 / 423 |
| 3.3 dual-cert server | defaults | OK; X25519MLKEM768, mldsa44 | 15,718 / 1,663 |
| 3.3 dual-cert server | X25519 + ECDSA only | OK; X25519, ecdsa_secp256r1_sha256 | 798 / 349 |

Where the bytes go:
- **ML-KEM in the ClientHello:** +1.2 KB from the 1,184-byte ML-KEM-768 encapsulation key. At 1,663 bytes, the ClientHello no longer fits in one 1,500-byte Ethernet frame.
- **ML-KEM in the ServerHello:** +1.1 KB for the 1,088-byte ciphertext.
- **ML-DSA authentication:** about 15 KB more than ECDSA (15.7 KB vs 0.8 KB). That is the 11.9 KB chain plus a 2.4 KB CertificateVerify signature.

### What a classical-only client does

- **No ML-KEM support:** the handshake fails against a server that accepts only the hybrid group. It silently falls back to X25519 when the server also allows classical groups. That fallback is a downgrade that monitoring should be able to detect.
- **No ML-DSA support:** the handshake fails against an ML-DSA-only server, because TLS has no way to skip authentication. It works only if the server also holds a classical certificate and selects it from the client's `signature_algorithms` (3.3).
- **Browsers currently fall into the no-ML-DSA group.** They negotiate the hybrid key exchange but do not accept ML-DSA certificates, so a browser pointed at the 3.1 server gets a handshake error. To test from the host, use `curl --cacert out/02/root.crt https://localhost:<port>/` or `s_client`.

### Limitations

- Everything ran on loopback. Packet loss, congestion windows and middleboxes were not measured.
- Only OpenSSL talked to OpenSSL. Browser and CDN behaviour was not tested.

### Migration implications

- **Key exchange first, signatures later.** Harvest-now-decrypt-later threatens confidentiality *today*. Authentication only has to be quantum-safe once a quantum computer exists, because a forged signature cannot be used retroactively. Hybrid ML-KEM is cheap (about 2.3 KB extra), degrades gracefully, and is the default from OpenSSL 3.5 on.
- **The size of ML-DSA authentication is a protocol problem.** A server flight of about 15.7 KB exceeds the TCP initial congestion window of 10 × MSS (about 14.6 KB, RFC 6928), which likely costs an extra round trip. QUIC's 3× anti-amplification limit makes it worse. Mitigations:
  - ML-DSA-44 leaves
  - short chains, with no cross-certificates sent
  - certificate compression (RFC 8879), although keys and signatures barely compress
  - longer term, approaches such as Merkle Tree Certificates
- **ClientHellos larger than one packet** break some middleboxes and load balancers that expect the ClientHello in a single packet. Test the WAF, IDS and load-balancer path before enabling hybrid key exchange.
- **The transition shape is dual certificates.** Servers need an ML-DSA certificate and a classical one (as in 3.3) until all clients support ML-DSA. Check that web servers, load balancers and HSM-backed key stores can hold two certificates per virtual host.

### Output files

| File | Content |
|---|---|
| `client-<port>-<scenario>.log` | Full `s_client` output per attempt: negotiated group, signature type, bytes transferred, errors |
| `server-<port>.log` | Server output |
| `ecdsa.key`, `ecdsa.crt` | Classical self-signed certificate, used only by the dual-cert server on 4433 |

---

## Step 4: ML-DSA CA keys in an HSM (PKCS#11 v3.2)

**Script:** [`scripts/04-hsm.sh`](scripts/04-hsm.sh) · **Output:** `out/04/` · **Requires:** step 2

Moves the CA into a SoftHSM2 token over PKCS#11 v3.2. Every key argument becomes a `pkcs11:token=pqc-hsm-lab;object=...` URI instead of a file.

A *token* is PKCS#11's term for one logical crypto device that holds keys: a smart card, a partition of a hardware HSM, or here SoftHSM2, which stores tokens as files. Programs reach a token through its PKCS#11 library: `libsofthsm2.so` here, or a vendor library for real hardware.

```
  openssl + pkcs11-provider  ─┐  generate keys, sign certs   (standard PKCS#11)
  softhsm2-util              ─┼► import an existing key      (SoftHSM-specific)
  pkcs11-tool (OpenSC)       ─┘  inspect: info, mechanisms, objects (standard PKCS#11)
                                       │
                                       ▼
              PKCS#11 library (libsofthsm2.so)  ──►  token "pqc-hsm-lab" (out/04/tokens/)
```

- **openssl + pkcs11-provider** asks the token to generate key pairs internally (`C_GenerateKeyPair`) and to sign with them. Only standard PKCS#11 calls are used, so the same commands work with any HSM that supports the ML-DSA mechanisms: point `pkcs11-module-path` at the vendor library.
- **softhsm2-util** imports a key generated elsewhere. It is SoftHSM-specific. Real HSMs ship their own import tools, and many accept keys only in wrapped (encrypted) form (`C_UnwrapKey`), never in plaintext.
- **pkcs11-tool** is used read-only, to show token info, mechanisms and objects.

Flow:
1. **Check the token.** It reports Cryptoki 3.2 and advertises the ML-DSA mechanisms.
2. **Generate inside the token (production pattern).** The root (ML-DSA-87) and issuing CA (ML-DSA-65) keys are generated as non-extractable. The step builds the same hierarchy as step 2 and verifies it. The leaf key remains a software key because it belongs to the TLS server, not to the CA.
3. **Import (migration pattern).** The step imports step 2's software root key, issues a certificate with it, and verifies that certificate against step 2's `root.crt`, which proves the key is the same.
4. **Compare key attributes** of generated and imported keys.

### Result: works, but only with SoftHSM2 built from unreleased source

```
ML-DSA mechanisms advertised by token                          YES   (Cryptoki 3.2; 0x1c keygen, 0x1d ML-DSA)
Generate root CA key ML-DSA-87 in token                        OK
Generate issuing CA key ML-DSA-65 in token                     OK
Root CA cert, self-signed by key in token                      OK
Issuing CA CSR, signed by its key in token                     OK
Issuing CA cert, signed by root key in token                   OK
Leaf cert, signed by issuing CA key in token                   OK
Verify chain leaf -> HSM issuing -> HSM root                   OK
Import step-2 root key (softhsm2-util --import)                OK
Issue a cert with the imported key in token                    OK
Verify it against step-2 root.crt (same key, now in token)     OK
```

- **The full two-tier ML-DSA CA ran with both CA keys inside the token.** Keys were generated through pkcs11-provider. Certificates were signed by passing `pkcs11:` URIs to `openssl req` and `openssl x509 -req`, with the same certificate profiles as step 2. Nothing in the OpenSSL commands is ML-DSA-specific.
- **Generated keys differ from imported keys:**
  - Generated keys are `sensitive, always sensitive, never extractable, local`.
  - The imported step 2 root key is only `sensitive`. It is neither `local` nor `always sensitive`, because the token knows the key existed outside it.
- **The `genpkey` output is a pointer, not a key.** `root-ca.uri.pem` is a PEM-wrapped PKCS#11 URI (enabled by `pkcs11-module-encode-provider-uri-to-pem`). By design, a non-extractable key cannot be written to a file.

### What it took

| layer | baseline (Debian trixie) | lab image (Arch + source build) |
|---|---|---|
| SoftHSM2 token | 2.6.1: Cryptoki 2.40, 70 mechanisms, **no ML-DSA**; segfaults at process exit under pkcs11-provider | `main` @ `7b9b2557`: Cryptoki 3.2, 107 mechanisms incl. ML-DSA; exit crash fixed (#897) |
| OpenSC `pkcs11-tool` | 0.26.1: does not know the ML-DSA key type | 0.27.1: knows it, but key generation fails against SoftHSM (below) |
| pkcs11-provider | 1.0: no ML-DSA | 1.3.0: ML-DSA keygen and signing work |
| OpenSSL | 3.5.7 | 4.1.0 |

SoftHSM2's ML-DSA support exists only on `main`, with **no release yet**. The latest tag, 2.7.0 from 2026-01-20, has the 3.2 header but no ML-DSA mechanism. The relevant upstream changes are:
- #809 (2026-03-14): ML-DSA in the library
- #867: multipart signing
- #870: `softhsm2-util` import
- #897 (2026-10-03): the exit-crash fix

The support is behind `--enable-mldsa`, requires OpenSSL ≥ 3.5, and the built library still reports version 2.7.

### Interop issue: pkcs11-tool key generation vs SoftHSM2

The lab generates keys only with openssl + pkcs11-provider. Generating the same key with OpenSC's `pkcs11-tool` fails with this tool combination. The script does not run this case; to reproduce it, run `make shell` after step 4, then:

```sh
SOFTHSM2_CONF=out/04/softhsm2.conf pkcs11-tool --module /opt/softhsm/lib/softhsm/libsofthsm2.so \
  --token-label pqc-hsm-lab --login --pin 1234 --keypairgen --key-type ML-DSA-65 --label x
```

The call fails with `CKR_ATTRIBUTE_READ_ONLY`:
- SoftHSM2 enforces the PKCS#11 3.2 rule that `CKA_PARAMETER_SET` **must not** appear in the *private*-key template of `C_GenerateKeyPair`; it belongs in the public-key template only. SoftHSM2's source marks it with the spec's "ck4" check for ML-DSA private keys.
- OpenSC 0.27.1 sets it in both templates.
- After the failed call, SoftHSM2 **leaves a half-created private key object** in the token (unlabelled, `ML-DSA: Unknown PARAMETER_SET`). That is a cleanup bug in SoftHSM2.
- pkcs11-provider builds a correct template and works. So does `softhsm2-util --import`.

### Limitations

- SoftHSM2 is a software token, with no physical tamper resistance and no FIPS validation. The step shows the *API* path, not HSM assurance.
- Key backup and transfer between tokens (wrap/unwrap of ML-DSA keys) was not covered. It is a real gap to test with any vendor.
- In a real migration, importing step 2's root key would be followed by destroying every software copy. The lab keeps `out/02/root.key` on purpose.
- The PIN is stored in a plain file (`pin.txt`).

### Migration implications

- **The HSM is the long pole.** OpenSSL has had ML-DSA since 3.5. The PKCS#11 stack works only with an unreleased SoftHSM2 plus the newest pkcs11-provider and OpenSC, and two PKCS#11 3.2 implementations still disagree on a key-generation template. Real HSMs add firmware upgrades, FIPS 140-3 re-validation and vendor SDK updates on top.
- **"Supports PKCS#11 3.2" is not the same as "supports ML-DSA".** SoftHSM2 2.7.0 shows exactly this: it reports 3.2 and has no ML-DSA mechanism. Check the mechanism list (`C_GetMechanismList`), not the version number.
- **Test the exact tool combination.** Two correct-looking components (OpenSC 0.27.1 and SoftHSM2 `main`) fail together. CA software, the PKCS#11 library and HSM firmware need an end-to-end test, not a feature checklist.
- **Generate CA keys in the HSM; import only if unavoidable.** An imported key can never prove it was never exposed: it lacks `always sensitive` and `never extractable`. For a new PQ root, a generate-in-HSM key ceremony is the clean path. Import only makes sense to rescue an existing software key, and every software copy must then be destroyed.
- **Questions for HSM vendors:**
  - Is ML-DSA exposed through *standard* PKCS#11 3.2 identifiers (`CKM_ML_DSA`), or through `CKM_VENDOR_DEFINED` mechanisms? Vendor-defined mechanisms lock you to one vendor's middleware.
  - Is ML-DSA covered by the module's **FIPS 140-3 / CMVP certificate**, rather than merely available?
  - Can ML-DSA keys be backed up and cloned between HSMs (wrap/unwrap)? Which private-key format is used (seed or expanded)?
  - Do object size limits accommodate a 4.9 KB ML-DSA-87 private key, a 2.6 KB public key and 7.5 KB certificates?
  - Which signing modes are supported: pure, HashML-DSA, "external mu"? Is pure ML-DSA available over large inputs (multipart)? X.509 and CMS need pure ML-DSA.
  - What is the ML-DSA signing throughput? Signing is slower than ECDSA.

### Output files

| File | Content |
|---|---|
| `softhsm2.conf` | Points SoftHSM at this directory for token storage |
| `tokens/<uuid>/` | The software token `pqc-hsm-lab`: the "HSM" |
| `pin.txt` | User PIN, read by pkcs11-provider |
| `openssl-pkcs11.cnf` | OpenSSL config that loads pkcs11-provider (used via `OPENSSL_CONF`) |
| `mechanisms.txt` | All mechanisms advertised by the token |
| `root-ca.uri.pem`, `issuing-ca.uri.pem` | Output of `genpkey`. These are **not keys**, only PEM-wrapped PKCS#11 URIs pointing at keys in the token |
| `root.crt`, `issuing.csr`, `issuing.crt` | HSM-backed root and issuing CA certificates |
| `leaf.key`, `leaf.csr`, `leaf.crt` | Server key (software), CSR, and certificate issued by the HSM issuing CA |
| `import-test.*` | Key, CSR and certificate issued by the *imported* step 2 root key |
| `try.log` | Output of the last attempted command |
| `summary.txt` | OK/FAILED summary table |

---

## Step 5: composite certificates

**Script:** [`scripts/05-composite.sh`](scripts/05-composite.sh) with [`scripts/Composite.java`](scripts/Composite.java) · **Output:** `out/05/`

Bouncy Castle (Java) creates self-signed CA certificates whose key and signature combine ML-DSA and ECDSA (RFC 10073). OpenSSL then tries to parse and verify one of them.

### Tooling: available, but not in OpenSSL

- Composite ML-DSA was published as **RFC 10073** (Standards Track, November 2026), from `draft-ietf-lamps-pq-composite-sigs`.
- **Bouncy Castle 1.86 (Java)** implements 18 composite combinations. The OIDs it produced in this lab match the RFC:
  - `MLDSA44-ECDSA-P256-SHA256` = 1.3.6.1.5.5.7.6.40
  - `MLDSA65-ECDSA-P256-SHA512` = .45
  - `MLDSA87-ECDSA-P384-SHA512` = .49
- **OpenSSL 3.5 and 4.1** have no composite support.
- **oqs-provider** is not an option: it *removed* composite signatures in 0.10.0, and its ML-DSA is disabled on OpenSSL ≥ 3.5.

### Results

| composite alg | pub | sig | cert (self-signed CA) | BC verify | OpenSSL 4.1 |
|---|---:|---:|---:|---|---|
| MLDSA44-ECDSA-P256-SHA256 | 1,398 | ~2,491 | 4,158 | OK | "Unable to load Public Key", verify fails |
| MLDSA65-ECDSA-P256-SHA512 | 2,038 | ~3,380 | 5,687 | OK | same |
| MLDSA87-ECDSA-P384-SHA512 | 2,710 | ~4,730 | 7,709 | OK | same |

The overhead over pure ML-DSA is small: about 64–96 B of public key and about 70–100 B of signature, which is the classical component.

### Limitations

- Only self-signed CA certificates were produced. There is no composite issuing CA and no composite TLS, because no mainstream TLS stack in the image can use them.
- No cross-library interop was tested, since no second implementation was available.

### Migration implications

- **Composite is a hedge, not a compatibility mechanism.** A composite signature is valid only if *all* component signatures verify (RFC 10073). That protects against ML-DSA turning out to be weak. But a classical-only verifier sees an unknown OID and fails, exactly as OpenSSL did here. Backward compatibility still requires dual certificates (step 3.3) or a parallel hierarchy.
- **Ecosystem support is the gating factor.** Every relying party, CA product, HSM and certificate parser must recognise the new OIDs. Today that means Java/Bouncy Castle-based stacks, not OpenSSL-based ones.
- **HSM impact:** PKCS#11 has no composite mechanism. A composite CA must hold *two* keys (ML-DSA and ECDSA) and combine the signatures in CA software. That puts a construction regulators care about (RFC 10073 §10.2 discusses FIPS treatment of the components) outside the HSM boundary.

### Output files

| File | Content |
|---|---|
| `MLDSA*-ECDSA-*.crt` | Three self-signed composite CA certificates |
| `sizes.txt` | Sizes and OIDs, and whether Bouncy Castle verified each certificate |
| `openssl-verify.log` | OpenSSL's verification attempt |

---

## Overall readiness

| area | baseline (Debian trixie) | lab image (current packages + source builds) |
|---|---|---|
| ML-DSA keys, certificates, chains | ✅ OpenSSL 3.5 | ✅ OpenSSL 4.1, 2–3× faster |
| Hybrid key exchange X25519MLKEM768 in TLS 1.3 | ✅ default, graceful fallback | ✅ same |
| ML-DSA authentication in TLS | ⚠️ works; about 15 KB per handshake; classical clients and browsers need a second certificate | ⚠️ same |
| ML-DSA keys in a PKCS#11 token | ❌ no packaged stack supports it | ⚠️ works with SoftHSM2 `main` (unreleased) + pkcs11-provider 1.3; `pkcs11-tool` interop bug |
| Composite certificates | ⚠️ RFC published; Bouncy Castle only | ⚠️ same; no OpenSSL support |

## References

- FIPS 204 (ML-DSA): https://csrc.nist.gov/pubs/fips/204/final
- RFC 9881, ML-DSA in X.509: https://www.rfc-editor.org/rfc/rfc9881
- RFC 10073, Composite ML-DSA: https://datatracker.ietf.org/doc/rfc10073/
- RFC 6928, TCP initial window: https://www.rfc-editor.org/rfc/rfc6928
- RFC 8879, TLS certificate compression: https://www.rfc-editor.org/rfc/rfc8879
- OpenSSL 4.1.0 NEWS (x86_64-optimised ML-DSA): https://github.com/openssl/openssl/blob/openssl-4.1.0/NEWS.md
- SoftHSMv2 repository and releases: https://github.com/softhsm/SoftHSMv2 , https://github.com/softhsm/SoftHSMv2/releases
- SoftHSMv2 ML-DSA PR #809: https://github.com/softhsm/SoftHSMv2/pull/809
- SoftHSMv2 exit segfault, issues #729 and #780: https://github.com/softhsm/SoftHSMv2/issues/729 , https://github.com/softhsm/SoftHSMv2/issues/780
- pkcs11-provider releases: https://github.com/latchset/pkcs11-provider/releases
- oqs-provider releases: https://github.com/open-quantum-safe/oqs-provider/releases
- Arch Linux Archive (package snapshot): https://archive.archlinux.org/
