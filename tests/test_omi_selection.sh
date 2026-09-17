#!/usr/bin/env bash
# Base-OMI selection. Pure parsing, no network: the fixture mirrors a real
# ReadImages response, with decoys for every disqualifying attribute.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
source "$(dirname "$0")/../build_scripts/lib/outscale_omi.sh"
FIX="$(dirname "$0")/fixtures/readimages-ubuntu.json"

pick() { UBUNTU_RELEASE="${2:-22.04}" osc_pick_latest_ubuntu "${2:-22.04}" < "$1"; }

it "picks the NEWEST matching image, not the first or last in the list"
assert_eq "ami-88dbc914" "$(pick "$FIX" | cut -f1)"

it "returns its name"
assert_eq "Ubuntu-22.04-2026-08-10" "$(pick "$FIX" | cut -f2)"

it "returns its creation date, for traceability"
assert_eq "2026-08-10T08:54:25.160141Z" "$(pick "$FIX" | cut -f3)"

# The decoys below are all NEWER than the expected answer, so each one proves its
# filter actually excludes rather than merely being unreachable.
it "ignores Ubuntu 24.04 -- not supported by Redis Enterprise"
assert_status 1 grep -q 'ami-deadbeef' <<<"$(pick "$FIX")"

it "ignores arm64 -- the build VM type is x86"
assert_status 1 grep -q 'ami-badarch' <<<"$(pick "$FIX")"

it "ignores instance-store -- the builder is outscale-bsu"
assert_status 1 grep -q 'ami-badroot' <<<"$(pick "$FIX")"

it "ignores images that are not yet available"
assert_status 1 grep -q 'ami-pending' <<<"$(pick "$FIX")"

it "ignores non-Ubuntu distributions"
assert_status 1 grep -q 'ami-debian' <<<"$(pick "$FIX")"

it "can select a different release when asked"
assert_eq "ami-deadbeef" "$(pick "$FIX" 24.04 | cut -f1)"

it "matches a dash-separated release name too (Ubuntu-22-04-...)"
TMPJ="$(mktemp)"
cat > "$TMPJ" <<'JSON'
{"Images":[{"ImageId":"ami-dash","ImageName":"Ubuntu-22-04-2026-09-09",
  "CreationDate":"2026-09-09T00:00:00Z","RootDeviceType":"bsu",
  "Architecture":"x86_64","State":"available"}]}
JSON
assert_eq "ami-dash" "$(osc_pick_latest_ubuntu 22.04 < "$TMPJ" | cut -f1)"
rm -f "$TMPJ"

it "prints nothing when no image matches"
assert_eq "" "$(echo '{"Images":[]}' | osc_pick_latest_ubuntu 22.04)"

it "survives a response with no Images key at all"
assert_eq "" "$(echo '{"ResponseContext":{}}' | osc_pick_latest_ubuntu 22.04)"

it "tolerates an image missing the optional Architecture field"
assert_eq "ami-noarch" "$(echo '{"Images":[{"ImageId":"ami-noarch","ImageName":"Ubuntu-22.04-x","CreationDate":"2026-01-01T00:00:00Z","RootDeviceType":"bsu","State":"available"}]}' | osc_pick_latest_ubuntu 22.04 | cut -f1)"

finish
