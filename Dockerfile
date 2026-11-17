# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Base: Arch Linux, pinned twice for reproducibility
#  1. image by digest (archlinux:latest, resolved 2026-11-10)
#  2. package repos to the Arch Linux Archive snapshot of 2026-11-10, because Arch is rolling and
#     `pacman -S` would otherwise pull whatever is newest on the day you build.
# Snapshot contents used here: OpenSSL 4.1.0, pkcs11-provider 1.3.0, OpenSC 0.27.1, JDK 21.0.13.
# ---------------------------------------------------------------------------
FROM archlinux:latest@sha256:d4594bb2300cba11f41c2f27923eb56f63d9988909c402f9c95517d1e362c899 AS base
RUN echo 'Server = https://archive.archlinux.org/repos/2026/11/10/$repo/os/$arch' > /etc/pacman.d/mirrorlist \
 && pacman -Syyuu --noconfirm --disable-download-timeout \
 && pacman -Scc --noconfirm

# ---------------------------------------------------------------------------
# Build stage: SoftHSM2 from source with ML-DSA.
# No SoftHSM release has ML-DSA yet (latest tag 2.7.0). It lives on `main`:
#   #809 ML-DSA in the library, #867 multipart ML-DSA, #870 ML-DSA in softhsm2-util,
#   #897 fix for the segfault at process exit under pkcs11-provider.
# Pinned to a full commit hash = what was `main` on 2026-11-11.
# ---------------------------------------------------------------------------
FROM base AS softhsm-build
RUN pacman -S --noconfirm --needed --disable-download-timeout base-devel git autoconf automake libtool pkgconf
ARG SOFTHSM_COMMIT=7b9b2557266f4f01a2ff29d043ab809cf6b568fb
RUN git init -q /src && cd /src \
 && git remote add origin https://github.com/softhsm/SoftHSMv2.git \
 && git fetch -q --depth 1 origin "$SOFTHSM_COMMIT" && git checkout -q FETCH_HEAD \
 && sh autogen.sh \
 # --enable-mldsa explicitly: configure fails if ML-DSA can't be built, instead of silently skipping it
 && ./configure --prefix=/opt/softhsm --sysconfdir=/opt/softhsm/etc --localstatedir=/var \
      --enable-mldsa --disable-gost \
 && make -j"$(nproc)" \
 && make install \
 && echo "$SOFTHSM_COMMIT" > /opt/softhsm/COMMIT

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM base
RUN pacman -S --noconfirm --needed --disable-download-timeout openssl pkcs11-provider opensc jdk21-openjdk \
 && pacman -Scc --noconfirm
# Own prefix: keeps it apart from distro files. Module: /opt/softhsm/lib/softhsm/libsofthsm2.so
COPY --from=softhsm-build /opt/softhsm /opt/softhsm
ENV PATH=/opt/softhsm/bin:$PATH

# Step 5 only: Bouncy Castle 1.86 (implements composite ML-DSA, RFC 10073 OIDs).
# Checksums verified against Maven Central's published .sha1 on 2026-11-10.
ADD --checksum=sha256:2af190b300cbb0b35e248ccf5f4a06b6072030aeb3da7a98ec73abe5b4cb371f \
    https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.86/bcprov-jdk18on-1.86.jar /opt/bc/
ADD --checksum=sha256:8d8b41a4b149bdae8d331f059a578870954d1e3ff29f8269a9eb3ee19a7e4ef7 \
    https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-jdk18on/1.86/bcpkix-jdk18on-1.86.jar /opt/bc/
ADD --checksum=sha256:1c268e15f785aafb1e4670d8d6e5f856f69475e96c162dadcd1ff9b350e9139f \
    https://repo1.maven.org/maven2/org/bouncycastle/bcutil-jdk18on/1.86/bcutil-jdk18on-1.86.jar /opt/bc/
RUN chmod 644 /opt/bc/*.jar

LABEL org.opencontainers.image.title="pqc-hsm-lab" \
      org.opencontainers.image.description="ML-DSA PKI migration lab: OpenSSL 4.1, SoftHSM2 (PKCS#11 v3.2), pkcs11-provider, Bouncy Castle"
WORKDIR /lab
