#!/usr/bin/env bash
# The build refuses to start when the target region has no base-OMI mapping, so the
# failure is a clear message instead of an empty source_omi reaching Packer (T-10).
# This pins the check against the REAL HCL, which is the part that can silently rot.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
HCL="$(cd "$(dirname "$0")/.." && pwd)/packer/redis_ubuntu_outscale_image.pkr.hcl"

# The predicate as used by build_and_deploy_redis_image_with_packer.sh
region_is_mapped() { grep -qE "\"${1}\"[[:space:]]*=" "$HCL"; }

it "eu-west-2 is mapped (the region every build so far has used)"
assert_status 0 region_is_mapped "eu-west-2"

it "an unmapped region is rejected"
assert_status 1 region_is_mapped "xx-west-9"

it "a region that is only a prefix of a mapped one is rejected"
assert_status 1 region_is_mapped "eu-west"

it "the mapped region resolves to a real-looking OMI ID"
omi="$(grep -E '"eu-west-2"[[:space:]]*=' "$HCL" | grep -oE 'ami-[0-9a-f]+')"
assert_eq "ami-054f16b1" "$omi"

it "the HCL declares the map, not a bare source_omi scalar"
assert_status 0 grep -q 'variable "source_omi_by_region"' "$HCL"

it "and the source block consumes the lookup"
assert_status 0 grep -qE 'source_omi[[:space:]]+=[[:space:]]+local\.source_omi' "$HCL"

it "the OMI name no longer claims to be AWS (T-18)"
assert_status 1 grep -q 'lts-aws-' "$HCL"

it "no personal path survives in the HCL (T-07)"
assert_status 1 grep -qE '/Users/[a-z]' "$HCL"

it "redis_version has no stale default (T-07)"
assert_status 1 grep -qE 'default[[:space:]]*=[[:space:]]*"7\.22' "$HCL"

it "redis_version carries a format validation"
assert_status 0 grep -q 'redis_version must look like' "$HCL"

finish
