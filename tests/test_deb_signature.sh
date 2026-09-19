#!/usr/bin/env bash
# The .deb signature check is the security-critical step of the build, so it is tested
# by EXECUTING the real function from the provisioning script against real signed,
# tampered and unsigned archives -- not by grepping for its presence.
#
# It exists because the build of 2026-09-18 10:07 died on "Unable to locate package
# dpkg-sig": the check used to depend on a universe-only Perl script. It now uses gpg
# directly, which means the logic is ours and must be tested.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/image_scripts/prepare-and-install-redis-install.sh"

for t in ar gpg tar; do
  command -v "$t" >/dev/null || { echo "  SKIP: $t absent" >&2; exit 0; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
bash "$(dirname "$0")/fixtures/make-signed-deb.sh" "$WORK" >/dev/null 2>&1 \
  || { echo "  SKIP: could not build the .deb fixtures" >&2; exit 0; }

# Extract verify_deb_manifest() from the script and source it, so the code under test
# is literally the shipped code.
FN="$WORK/fn.sh"
sed -n '/^verify_deb_manifest() {/,/^}/p' "$SCRIPT" > "$FN"
it "the function can be extracted from the provisioning script"
assert_status 0 test -s "$FN"

# shellcheck source=/dev/null
source "$FN"
export GNUPGHOME="$WORK/gnupg"

it "accepts a correctly signed .deb"
assert_status 0 verify_deb_manifest "$WORK/signed.deb"

it "reports a good signature"
assert_contains "$(verify_deb_manifest "$WORK/signed.deb" 2>&1)" "Good signature"

it "REJECTS a .deb whose contents were altered after signing"
assert_fails verify_deb_manifest "$WORK/tampered.deb"

it "and says the signature is bad"
assert_contains "$(verify_deb_manifest "$WORK/tampered.deb" 2>&1)" "BAD signature"

it "REJECTS an unsigned .deb instead of passing it"
assert_fails verify_deb_manifest "$WORK/unsigned.deb"

it "and says it carries no _gpgorigin"
assert_contains "$(verify_deb_manifest "$WORK/unsigned.deb" 2>&1)" "NOT signed"

it "REJECTS a signed .deb when the signing key is unknown"
EMPTY="$WORK/empty-gnupg"; mkdir -p "$EMPTY"; chmod 700 "$EMPTY"
# gpg exits 2 here ("Can't check signature: No public key"), not 1 -- the contract is
# that an unverifiable package is refused, whatever the precise code.
assert_fails env GNUPGHOME="$EMPTY" bash -c \
  "source '$FN'; verify_deb_manifest '$WORK/signed.deb'"

it "REJECTS a file that is not an ar archive at all"
echo "not an archive" > "$WORK/bogus.deb"
assert_fails verify_deb_manifest "$WORK/bogus.deb"

# ---------- the format Redis actually ships: a clearsigned manifest ----------
# An earlier implementation assumed _gpgorigin was a detached signature over the
# concatenated members. The real package answered "gpg: not a detached signature".
it "recognises the dpkg-sig clearsigned-manifest format"
assert_contains "$(verify_deb_manifest "$WORK/manifest-signed.deb" 2>&1)" "clearsigned manifest"

it "accepts a valid manifest-signed .deb"
assert_status 0 verify_deb_manifest "$WORK/manifest-signed.deb"

it "verifies every member listed in the manifest, not just the signature"
assert_contains "$(verify_deb_manifest "$WORK/manifest-signed.deb" 2>&1)" "3 member(s) verified"

it "REJECTS a member altered after signing, even though the signature is still valid"
# The case a naive "the manifest signature is good" check would wave through.
assert_fails verify_deb_manifest "$WORK/manifest-tampered.deb"

it "and names the member that does not match"
assert_contains "$(verify_deb_manifest "$WORK/manifest-tampered.deb" 2>&1)" "does not match the signed manifest"

it "still handles the debsigs detached-signature format"
assert_contains "$(verify_deb_manifest "$WORK/signed.deb" 2>&1)" "detached signature"

finish
