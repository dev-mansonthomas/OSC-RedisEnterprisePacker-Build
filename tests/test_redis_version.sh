#!/usr/bin/env bash
# Pure-function tests for build_scripts/lib/redis_version.sh. No network.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
source "$(dirname "$0")/../build_scripts/lib/redis_version.sh"

# ---------- version shape ----------
it "accepts a well-formed version"
assert_status 0 rcv_is_valid_version "8.2.0-78"

it "accepts a two-digit minor (7.22.0-95 shipped like this)"
assert_status 0 rcv_is_valid_version "7.22.0-95"

it "rejects a version with no build number"
assert_status 1 rcv_is_valid_version "8.2.0"

it "rejects an empty version"
assert_status 1 rcv_is_valid_version ""

it "rejects a version with trailing junk"
assert_status 1 rcv_is_valid_version "8.2.0-78-jammy"

# ---------- filename -> version (the T-05 bug) ----------
it "extracts the version from a real tarball name"
assert_eq "8.0.2-41" "$(rcv_version_from_filename redislabs-8.0.2-41-jammy-amd64.tar)"

it "works on a full path"
assert_eq "8.2.0-78" "$(rcv_version_from_filename /tmp/x/redislabs-8.2.0-78-jammy-amd64.tar)"

it "returns EMPTY for a non-matching name -- the original returned the basename"
assert_eq "" "$(rcv_version_from_filename redislabs-garbage.tar 2>/dev/null)"

it "and exits non-zero so the caller can detect it"
assert_status 4 rcv_version_from_filename redislabs-garbage.tar

it "rejects a name that is close but missing the build number"
assert_status 4 rcv_version_from_filename redislabs-8.0.2-jammy-amd64.tar

# ---------- URL construction (verified live: all three return HTTP 200) ----------
it "builds the download URL with the build number stripped from the directory"
assert_eq \
  "https://s3.amazonaws.com/redis-enterprise-software-downloads/8.2.0/redislabs-8.2.0-78-jammy-amd64.tar" \
  "$(rcv_tarball_url 8.2.0-78)"

it "handles a two-digit minor in the directory component"
assert_eq \
  "https://s3.amazonaws.com/redis-enterprise-software-downloads/7.22.0/redislabs-7.22.0-95-jammy-amd64.tar" \
  "$(rcv_tarball_url 7.22.0-95)"

it "honours REDIS_DOWNLOAD_BASE_URL"
assert_eq "https://example.test/8.0.2/redislabs-8.0.2-41-jammy-amd64.tar" \
  "$(REDIS_DOWNLOAD_BASE_URL=https://example.test rcv_tarball_url 8.0.2-41)"

it "refuses to build a URL from a malformed version"
assert_status 2 rcv_tarball_url "not-a-version"

it "builds the expected tarball filename"
assert_eq "redislabs-8.0.2-41-jammy-amd64.tar" "$(rcv_tarball_name 8.0.2-41)"

# ---------- ordering ----------
it "orders 8.0.2-41 before 8.2.0-78"
assert_eq "-1" "$(rcv_compare_versions 8.0.2-41 8.2.0-78)"

it "orders 8.2.0-78 after 8.0.2-41"
assert_eq "1" "$(rcv_compare_versions 8.2.0-78 8.0.2-41)"

it "treats equal versions as equal"
assert_eq "0" "$(rcv_compare_versions 8.2.0-78 8.2.0-78)"

it "compares build numbers numerically, not lexically (9 < 78)"
assert_eq "-1" "$(rcv_compare_versions 8.2.0-9 8.2.0-78)"

it "orders 7.22.0 after 7.8.0 (minor compared numerically)"
assert_eq "1" "$(rcv_compare_versions 7.22.0-95 7.8.0-10)"

finish
