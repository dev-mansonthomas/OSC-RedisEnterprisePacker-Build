#!/usr/bin/env bash
# Contract tests for image_scripts/prepare-and-install-redis-install.sh.
#
# The script only runs as root inside a Packer build VM, so these are static checks on
# its guarantees rather than an execution. Each one corresponds to a finding whose
# regression would be invisible until a customer audited the published image.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
P="$(cd "$(dirname "$0")/.." && pwd)/image_scripts/prepare-and-install-redis-install.sh"

# ---------- T-13: GPG trust must not be circular ----------
it "pins the expected Redis signing-key fingerprint in the repository"
assert_status 0 grep -qE 'REDIS_GPG_FINGERPRINT="\$\{REDIS_GPG_FINGERPRINT:-[0-9A-F]{40}\}"' "$P"

it "checks the fingerprint BEFORE importing, so a hostile key never enters the keyring"
fpr_line="$(grep -n 'import-options show-only' "$P" | cut -d: -f1)"
imp_line="$(grep -n '^gpg --import "\$GPG_KEY_FILE"' "$P" | cut -d: -f1)"
assert_status 0 test "$fpr_line" -lt "$imp_line"

it "aborts on a fingerprint mismatch rather than warning"
assert_contains "$(sed -n "/unexpected Redis signing key/,/^fi/p" "$P")" "exit 1"

it "explains that a mismatch may mean key rotation, not only tampering"
assert_contains "$(cat "$P")" "Redis rotated its signing key"

it "refuses to proceed if the key file is missing from the tarball"
assert_contains "$(cat "$P")" "Redis GPG key not found in the tarball"

it "verifies exactly one .deb, so a layout change cannot silently pass"
assert_contains "$(cat "$P")" "expected exactly one redislabs_*.deb"

# ---------- the 2026-09-18 10:07 build failure ----------
# "E: Unable to locate package dpkg-sig": apt had indexed only jammy-updates,
# jammy-security and jammy-backports, never the jammy release pocket, so every
# universe-only package vanished while everything else still installed.
it "waits for cloud-init before touching apt, which is what caused the partial index"
ci_line="$(grep -n 'cloud-init status --wait' "$P" | head -1 | cut -d: -f1)"
apt_line="$(grep -n 'apt-get update -y' "$P" | head -1 | cut -d: -f1)"
assert_status 0 test "$ci_line" -lt "$apt_line"

it "guarantees the release pocket with universe is present"
assert_contains "$(cat "$P")" "main restricted universe multiverse"

it "retries apt-get update instead of failing on a transient mirror error"
assert_contains "$(cat "$P")" "retrying in 10s"

it "does NOT abort the build over a convenience package"
# The 10:26 build died because iotop was judged unavailable. A diagnostic tool is not
# worth a ~5 minute build and a publishable image.
assert_contains "$(cat "$P")" "none of them is required by Redis Enterprise"

it "installs conveniences one at a time, so one bad package cannot block the rest"
assert_status 0 grep -qF 'for pkg in $UTILS; do' "$P"

it "prints apt-cache policy for whatever it could not install, for diagnosis"
assert_status 0 grep -qF 'apt-cache policy "$pkg"' "$P"

it "but DOES abort when the signature tooling is missing"
assert_contains "$(sed -n '/Hard requirements/,/Signature verification tooling/p' "$P")" "exit 1"

it "requires gpg and ar, the two things the signature check cannot do without"
assert_contains "$(cat "$P")" 'for req in gpg ar; do'

it "treats dpkg-sig as a convenience, not a requirement"
assert_status 0 grep -qE '^UTILS=.*dpkg-sig' "$P"

it "prints the APT sources actually in effect, for post-mortem"
assert_contains "$(cat "$P")" "APT sources in effect"

it "uses netcat-openbsd rather than the transitional netcat package"
assert_contains "$(cat "$P")" "netcat-openbsd"

it "and no longer installs the bare 'netcat' virtual package"
assert_status 1 grep -qE 'install .*[[:space:]]netcat[[:space:]]' "$P"

# ---------- the signature check must not depend on a universe package ----------
it "uses dpkg-sig as the authority when present -- it is the reference implementation"
assert_status 0 grep -qE 'if command -v dpkg-sig' "$P"

it "and falls back to its own verifier when dpkg-sig is absent"
assert_contains "$(cat "$P")" "verify_deb_manifest"

it "the fallback handles the clearsigned-manifest format Redis actually ships"
assert_contains "$(cat "$P")" "clearsigned manifest (dpkg-sig format)"

it "and still handles the debsigs detached-signature format"
assert_contains "$(cat "$P")" "detached signature (debsigs format)"

it "fails the build when neither path can verify the package"
assert_contains "$(sed -n '/Verifying the signature of/,/^fi$/p' "$P")" "exit 1"

it "keeps dpkg-sig installable but non-fatal, so its absence degrades rather than blocks"
assert_status 0 grep -qE '^UTILS=.*dpkg-sig' "$P"

it "records why dpkg-sig came back as the authority"
assert_contains "$(cat "$P")" "not a detached signature"

# ---------- T-11: the image must not carry a shared identity ----------
it "removes the SSH host keys"
assert_status 0 grep -qE '^rm -f /etc/ssh/ssh_host_\*' "$P"

it "clears machine-id by truncation, so systemd still finds the file"
assert_status 0 grep -qE '^: > /etc/machine-id' "$P"

it "and never deletes it outright, which can break boot"
assert_status 1 grep -qE '^rm -f /etc/machine-id$' "$P"

it "removes the dbus machine-id too"
assert_contains "$(cat "$P")" "/var/lib/dbus/machine-id"

it "clears cloud-init state so a launched VM does not think it already ran"
assert_contains "$(cat "$P")" "cloud-init clean"

it "degrades when cloud-init lacks --seed instead of failing the build"
assert_contains "$(cat "$P")" "cloud-init has no --seed"

it "drops any authorized_keys baked in during the build"
assert_contains "$(cat "$P")" "authorized_keys"

# ---------- T-31: the installer payload must not ship ----------
it "deletes the uploaded tarball"
assert_status 0 grep -qE '^rm -f  /home/\$USER/redis-enterprise\.tar' "$P"

it "deletes the extracted tree"
assert_status 0 grep -qE '^rm -rf /home/\$USER/redis-enterprise$' "$P"

it "removes the gnupg home holding the imported signing key"
assert_contains "$(cat "$P")" "rm -rf /home/\$USER/.gnupg"

it "removes the provisioning script Packer uploaded"
# Found still present on a VM launched from ami-57a302f4.
assert_contains "$(cat "$P")" "rm -f  /home/\$USER/prepare-and-install-redis-install.sh"

it "and the installer answer file"
assert_contains "$(cat "$P")" "rm -f  /home/\$USER/redis-install-answers.txt"

it "cleans the apt cache"
assert_contains "$(cat "$P")" "apt-get clean"

it "and the package lists"
assert_contains "$(cat "$P")" "rm -rf /var/lib/apt/lists/*"

# ---------- T-12: time sync must be asserted, not assumed ----------
it "asserts that network time synchronisation is enabled"
assert_contains "$(cat "$P")" "timedatectl show -p NTP --value"

it "fails the build when it is not"
assert_contains "$(sed -n '/network time synchronisation is not enabled/,/^fi/p' "$P")" "exit 1"

it "keeps ntp=no in the answer file -- a second time daemon would be worse"
ANS="$(dirname "$P")/redis-install-answers.txt"
assert_status 0 grep -qx 'ntp=no' "$ANS"

# ---------- ordering: cleanup must be last ----------
it "installs Redis Enterprise BEFORE de-identifying"
inst="$(grep -n 'bash ./install.sh' "$P" | cut -d: -f1)"
deid="$(grep -n 'De-identifying the image' "$P" | tail -1 | cut -d: -f1)"
assert_status 0 test "$inst" -lt "$deid"

it "reclaims the payload BEFORE de-identifying, so both still run if one is edited"
recl="$(grep -n 'Reclaiming installer payload' "$P" | tail -1 | cut -d: -f1)"
assert_status 0 test "$recl" -lt "$deid"

it "asserts time sync BEFORE cleanup, while the system is still fully inspectable"
ntp="$(grep -n 'Verifying time synchronisation' "$P" | tail -1 | cut -d: -f1)"
assert_status 0 test "$ntp" -lt "$recl"

it "de-identification is the last thing the script does"
last="$(grep -n 'Image ready' "$P" | cut -d: -f1)"
assert_status 0 test "$deid" -lt "$last"

# ---------- T-13, functionally: the fingerprint gate really gates ----------
# Static greps prove the code is present; this proves it WORKS, by running the same
# extraction and comparison against a real key with a correct and an incorrect pin.
if command -v gpg >/dev/null; then
  GH="$(mktemp -d)"; chmod 700 "$GH"
  export GNUPGHOME="$GH"
  gpg --batch --quiet --passphrase '' \
      --quick-generate-key 'Fixture <f@example.test>' default default 0 2>/dev/null
  gpg --export --armor 'f@example.test' > "$GH/key.asc" 2>/dev/null
  REAL_FPR="$(gpg --with-colons --fingerprint 'f@example.test' 2>/dev/null \
              | awk -F: '$1=="fpr"{print $10}' | head -1)"

  # Exactly the extraction the script performs.
  extract() {
    gpg --with-colons --import-options show-only --import "$1" 2>/dev/null \
      | awk -F: '$1 == "fpr" { print $10 }'
  }
  gate() { printf '%s\n' "$(extract "$1")" | grep -qx "$2"; }

  it "extracts a fingerprint from a key FILE without importing it"
  assert_contains "$(extract "$GH/key.asc")" "$REAL_FPR"

  it "accepts the key when the pin matches"
  assert_status 0 gate "$GH/key.asc" "$REAL_FPR"

  it "REJECTS the key when the pin does not match"
  assert_status 1 gate "$GH/key.asc" "0000000000000000000000000000000000000000"

  it "rejects a pin that is merely a prefix of the real fingerprint"
  assert_status 1 gate "$GH/key.asc" "${REAL_FPR:0:16}"

  it "show-only leaves the keyring untouched"
  EMPTY="$(mktemp -d)"; chmod 700 "$EMPTY"
  GNUPGHOME="$EMPTY" gpg --with-colons --import-options show-only \
    --import "$GH/key.asc" >/dev/null 2>&1
  assert_eq "" "$(GNUPGHOME="$EMPTY" gpg --list-keys 2>/dev/null | grep . || true)"

  unset GNUPGHOME
  rm -rf "$GH" "$EMPTY"
else
  echo "  SKIP gpg absent: fingerprint-gate functional tests not run" >&2
fi

# ---------- T-19: the host firewall ----------
it "installs the firewall helper into the image, so RUN can re-scope it"
assert_contains "$(cat "$P")" "/usr/local/sbin/redis-enterprise-firewall"

it "applies the firewall AFTER install.sh, not before"
fw="$(grep -n 'Applying the build-time firewall' "$P" | cut -d: -f1)"
inst="$(grep -n 'bash ./install.sh' "$P" | cut -d: -f1)"
assert_status 0 test "$inst" -lt "$fw"

it "asserts ufw ends up active rather than trusting it"
assert_contains "$(cat "$P")" "ufw is not active after applying the rules"

it "refuses to publish an image with no SSH rule"
assert_contains "$(cat "$P")" "refusing to publish an unreachable image"

it "fails when ufw is absent instead of silently skipping the firewall"
assert_contains "$(cat "$P")" "ufw is not installed; cannot apply the host firewall"

it "keeps firewall=no, so install.sh does not add a competing rule set"
assert_status 0 grep -qx 'firewall=no' "$(dirname "$P")/redis-install-answers.txt"

it "explains why firewall=no is deliberate rather than leftover"
assert_contains "$(cat "$P")" "two sources of truth for the same"

it "removes the uploaded firewall script from the image"
assert_contains "$(cat "$P")" "rm -f  /home/\$USER/redis-enterprise-firewall.sh"

it "the Packer template uploads the firewall script"
HCL="$(cd "$(dirname "$P")/.." && pwd)/packer/redis_ubuntu_outscale_image.pkr.hcl"
assert_contains "$(cat "$HCL")" "redis-enterprise-firewall.sh"

it "which means four file provisioners now, not three"
assert_eq "4" "$(grep -c 'provisioner "file"' "$HCL")"

finish
