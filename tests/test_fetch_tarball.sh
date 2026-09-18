#!/usr/bin/env bash
# Integration tests for fetch_redis_tarball.sh that need no network and never touch
# the real ~1 GB tarball: each case runs against a throwaway REPO_ROOT.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/build_scripts/fetch_redis_tarball.sh"
LIB="$(cd "$(dirname "$0")/.." && pwd)/build_scripts/lib/redis_version.sh"

# Build a fake repo root holding only what the script needs.
make_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/build_scripts/lib" "$d/redis-software"
  cp "$SCRIPT" "$d/build_scripts/"
  cp "$LIB" "$d/build_scripts/lib/"
  printf '%s' "$d"
}
run_in() { local d="$1"; shift; ( cd "$d" && bash build_scripts/fetch_redis_tarball.sh "$@" 2>&1 ); }

# ---------- no tarball ----------
S="$(make_sandbox)"
it "fails when redis-software/ is empty"
out="$(run_in "$S" --skip-version-check)"; rc=$?
assert_eq "1" "$rc"
it "and says so clearly"
assert_contains "$out" "no Redis Enterprise tarball"
rm -rf "$S"

# ---------- one tarball ----------
S="$(make_sandbox)"
echo "fake payload" > "$S/redis-software/redislabs-8.0.2-41-jammy-amd64.tar"
# First invocation only: it both reports the version AND records the digest.
first_run="$(run_in "$S" --skip-version-check)"

it "accepts exactly one tarball and reports its version"
assert_contains "$first_run" "REDIS_VERSION=8.0.2-41"

it "records the digest on first sight"
assert_contains "$first_run" "Digest: recorded"

it "verifies against the recorded digest on subsequent runs"
assert_contains "$(run_in "$S" --skip-version-check)" "Digest: verified"

it "detects a tampered tarball -- exits non-zero"
echo "TAMPERED" > "$S/redis-software/redislabs-8.0.2-41-jammy-amd64.tar"
out="$(run_in "$S" --skip-version-check)"; rc=$?
assert_eq "1" "$rc"
it "and names the mismatch"
assert_contains "$out" "DIGEST MISMATCH"
rm -rf "$S"

# ---------- two tarballs: the T-05 silent-wrong-answer case ----------
S="$(make_sandbox)"
echo a > "$S/redis-software/redislabs-8.0.2-41-jammy-amd64.tar"
echo b > "$S/redis-software/redislabs-8.2.0-78-jammy-amd64.tar"
it "refuses to guess between two tarballs (old code took the older one)"
out="$(run_in "$S" --skip-version-check)"; rc=$?
assert_eq "1" "$rc"
it "and explains what to do"
assert_contains "$out" "ambiguous"
rm -rf "$S"

# ---------- unparseable name ----------
S="$(make_sandbox)"
echo x > "$S/redis-software/redislabs-nonsense.tar"
it "rejects a tarball whose name carries no usable version"
out="$(run_in "$S" --skip-version-check)"; rc=$?
assert_eq "1" "$rc"
it "and says the name is the problem"
assert_contains "$out" "cannot be parsed"
rm -rf "$S"

# ---------- argument handling ----------
S="$(make_sandbox)"
echo x > "$S/redis-software/redislabs-8.0.2-41-jammy-amd64.tar"
it "rejects a malformed --version"
out="$(run_in "$S" --version 8.2)"; rc=$?
assert_eq "1" "$rc"
it "rejects an unknown argument with the usage exit code"
out="$(run_in "$S" --nope)"; rc=$?
assert_eq "2" "$rc"
it "accepts a pinned version equal to the local one"
assert_contains "$(run_in "$S" --version 8.0.2-41)" "Up to date."
rm -rf "$S"

# ---------- a new download parks the superseded tarball in old/ ----------
# Exercised with a local file:// URL so no ~350 MB transfer is involved.
S="$(make_sandbox)"
echo "old payload" > "$S/redis-software/redislabs-8.0.2-41-jammy-amd64.tar"
SERVE="$(mktemp -d)"; mkdir -p "$SERVE/8.2.0"
echo "new payload" > "$SERVE/8.2.0/redislabs-8.2.0-78-jammy-amd64.tar"
out="$( cd "$S" && REDIS_DOWNLOAD_BASE_URL="file://$SERVE" \
        bash build_scripts/fetch_redis_tarball.sh --download --version 8.2.0-78 2>&1 )"

it "downloads the new version"
assert_contains "$out" "redislabs-8.2.0-78-jammy-amd64.tar"

it "reports that it parked the previous one"
assert_contains "$out" "Moved"

it "the new tarball is the only one at the top level"
assert_eq "1" "$(find "$S/redis-software" -maxdepth 1 -name 'redislabs-*.tar' | wc -l)"

it "and it is the new version"
assert_eq "redislabs-8.2.0-78-jammy-amd64.tar" "$(basename "$(find "$S/redis-software" -maxdepth 1 -name 'redislabs-*.tar')")"

it "the superseded tarball is in old/, not deleted -- a failed build can roll back"
assert_eq "redislabs-8.0.2-41-jammy-amd64.tar" "$(basename "$(find "$S/redis-software/old" -name 'redislabs-*.tar')")"

it "and its content is intact"
assert_eq "old payload" "$(cat "$S/redis-software/old/redislabs-8.0.2-41-jammy-amd64.tar")"

it "a parked tarball does not make the inventory ambiguous"
assert_contains "$( cd "$S" && bash build_scripts/fetch_redis_tarball.sh --skip-version-check 2>&1 )" \
  "REDIS_VERSION=8.2.0-78"
rm -rf "$S" "$SERVE"

finish
