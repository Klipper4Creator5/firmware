#!/usr/bin/env bash
# Make the keypair the package feed is signed with.
#
#     ./bin/apk-keygen.sh ~/.anvil/anvil.rsa
#
# Writes the private key at the path given and the public half beside it as
# <path>.pub, then tells you the two lines to add.
#
# OUTSIDE THE REPO, ALWAYS. The path goes in config.env, which is gitignored,
# and the key itself should live somewhere the repository cannot reach --
# losing control of it means someone else can build packages this fleet
# accepts. It is not in vendor/ and there is no `make` target that would put
# it there.
#
# RSA, NOT EC. apk signs with EVP_DigestSign and sets no padding override
# (src/crypto_openssl.c), so RSA is PKCS#1 v1.5 -- deterministic, which is
# what lets two builds of one tree stay byte-identical. ECDSA signatures carry
# a random nonce and would break that, silently, in a way only the
# reproducibility test would catch.
set -euo pipefail

KEY=${1:-}
[ -n "$KEY" ] || {
    echo "usage: ./bin/apk-keygen.sh <path-to-private-key>" >&2
    echo "   e.g. ./bin/apk-keygen.sh ~/.anvil/anvil.rsa" >&2
    exit 1; }

[ -e "$KEY" ] && {
    echo "!! $KEY already exists, and overwriting it would orphan every" >&2
    echo "   printer that trusts the current key. Move it aside first." >&2
    exit 1; }

mkdir -p "$(dirname "$KEY")"
# 0077 so the key is never briefly world-readable between creation and chmod.
_um=$(umask); umask 0077
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY" >/dev/null 2>&1
umask "$_um"
openssl pkey -in "$KEY" -pubout -out "$KEY.pub" >/dev/null 2>&1

echo "private key: $KEY"
echo "public key:  $KEY.pub"
echo
echo "Add to config.env:"
echo "    APK_SIGN_KEY=\"$KEY\""
echo
echo "The public half is copied into the feed's trust directory by"
echo "bin/build-packages.sh and ships in anvil-core, so printers can verify"
echo "what they are offered. Keep the private key; there is no way to reissue"
echo "it to a printer except by flashing a .tgz."
