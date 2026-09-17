#!/usr/bin/env bash
# The OMI ID that Run consumes is extracted from manifest.json with jq. Getting this
# wrong launches the WRONG IMAGE (docs/TODO.md T-01, T-06), so the expression and its
# failure modes are pinned here.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
FIX="$(dirname "$0")/fixtures"

# The expression as used by build_scripts/build_and_deploy_redis_image_with_packer.sh
extract_ami() {
  local mf="$1"
  jq -r --arg uuid "$(jq -r '.last_run_uuid' "$mf")" \
    '.builds[] | select(.packer_run_uuid == $uuid) | .artifact_id' "$mf" | cut -d':' -f2
}

it "picks the artifact matching last_run_uuid, not the newest or the first"
assert_eq "ami-06426132" "$(extract_ami "$FIX/manifest-ok.json")"

it "yields the region-stripped ID only"
assert_contains "$(extract_ami "$FIX/manifest-ok.json")" "ami-"

it "returns EMPTY when last_run_uuid matches no build -- the T-06 silent failure"
assert_eq "" "$(extract_ami "$FIX/manifest-stale-uuid.json")"

# --- the guard that T-06 adds; kept here so the regex itself is pinned ---
valid_ami() { [[ "$1" =~ ^ami-[0-9a-f]+$ ]]; }

it "accepts a well-formed OMI ID"
assert_status 0 valid_ami "ami-06426132"

it "rejects an empty ID (what the stale-uuid case produces)"
assert_status 1 valid_ami ""

it "rejects a region-prefixed ID (cut -d: forgotten)"
assert_status 1 valid_ami "eu-west-2:ami-06426132"

it "rejects an uppercase/garbage ID"
assert_status 1 valid_ami "AMI-XYZ"

finish
