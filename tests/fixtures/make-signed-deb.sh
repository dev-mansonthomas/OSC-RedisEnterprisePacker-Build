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

# --- dpkg-sig format: a CLEARSIGNED MANIFEST, not a detached signature ---
# This is what Redis actually ships. Discovered when a detached-signature
# implementation met "gpg: not a detached signature" on the real package.
# Format: header fields, then a Files: block of "<md5> <sha1> <size> <member>".
{
  echo "Version: 4"
  echo "Signer: Deb Fixture"
  echo "Date: $(date -R)"
  echo "Role: origin"
  echo "Files: "
  for m in debian-binary control.tar.gz data.tar.gz; do
    printf '\t%s %s %s %s\n' \
      "$(md5sum "$m" | cut -d' ' -f1)" \
      "$(sha1sum "$m" | cut -d' ' -f1)" \
      "$(wc -c < "$m" | tr -d ' ')" \
      "$m"
  done
} > .manifest

gpg --batch --yes --clearsign -o .manifest.asc .manifest 2>/dev/null
cp unsigned.deb manifest-signed.deb
cp .manifest.asc _gpgorigin_manifest
# ar stores the member under its basename, so stage it with the right name.
cp .manifest.asc _gpgorigin
ar rb debian-binary manifest-signed.deb _gpgorigin 2>/dev/null

# Same manifest, but a member altered afterwards: signature valid, checksums wrong.
# This is the case a naive "verify the manifest signature" check would wave through.
cp manifest-signed.deb manifest-tampered.deb
ar x manifest-tampered.deb data.tar.gz --output "$OUT" 2>/dev/null || ar p manifest-tampered.deb data.tar.gz > data.tar.gz
echo "tampered" >> data.tar.gz
ar r manifest-tampered.deb data.tar.gz 2>/dev/null

rm -rf .c .d .payload .manifest .manifest.asc _gpgorigin _gpgorigin_manifest
