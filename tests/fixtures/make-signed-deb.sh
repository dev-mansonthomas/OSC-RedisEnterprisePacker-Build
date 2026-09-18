#!/usr/bin/env bash
# Builds three .deb fixtures in $1: signed.deb, tampered.deb, unsigned.deb, plus a
# gnupg home holding the signing key. Used by tests/test_deb_signature.sh.
#
# A signed .deb is an ar archive whose _gpgorigin member is a detached signature over
# the concatenation of the other members in archive order -- the same shape dpkg-sig
# produces, so the fixtures exercise the real format rather than an approximation.
set -euo pipefail
OUT="${1:?usage: make-signed-deb.sh <outdir>}"
mkdir -p "$OUT"; cd "$OUT"

export GNUPGHOME="$OUT/gnupg"
rm -rf "$GNUPGHOME"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' \
    --quick-generate-key 'Deb Fixture <fixture@example.test>' default default 0 2>/dev/null

echo "2.0" > debian-binary
mkdir -p .c .d
echo "Package: fixture" > .c/control
echo "payload" > .d/file
tar czf control.tar.gz -C .c . 2>/dev/null
tar czf data.tar.gz -C .d . 2>/dev/null

ar rc unsigned.deb debian-binary control.tar.gz data.tar.gz 2>/dev/null
ar p unsigned.deb debian-binary control.tar.gz data.tar.gz > .payload
gpg --batch --yes --detach-sign -o _gpgorigin .payload 2>/dev/null

cp unsigned.deb signed.deb
ar rb debian-binary signed.deb _gpgorigin 2>/dev/null

# Flip a byte inside the data member, leaving the signature intact.
cp signed.deb tampered.deb
printf 'X' | dd of=tampered.deb bs=1 seek=250 conv=notrunc 2>/dev/null

rm -rf .c .d .payload
