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
assert_status 0 grep -qE '^ami-[0-9a-f]{8}$' <<<"$omi"

it "and is NOT the deregistered ami-054f16b1 (gone upstream 2026-09-17)"
assert_status 1 grep -qE '"eu-west-2"[[:space:]]*=[[:space:]]*"ami-054f16b1"' "$HCL"

# The wrapper must check the OMI still exists: packer validate cannot, it only
# requires source_omi to be non-empty. This is the failure mode that actually bit.
WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/build_scripts/build_and_deploy_redis_image_with_packer.sh"

it "the wrapper resolves source_omi from the region map"
assert_status 0 grep -q 'SOURCE_OMI=' "$WRAPPER"

it "and verifies it exists via ReadImages before invoking packer"
assert_status 0 grep -q 'ReadImages' "$WRAPPER"

it "the check is skippable, so a stale ID never hard-blocks a deliberate build"
assert_status 0 grep -q 'SKIP_OMI_CHECK' "$WRAPPER"

it "and degrades quietly when oapi-cli is absent (the VM case)"
assert_status 0 grep -q 'command -v oapi-cli' "$WRAPPER"

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

# Asserted structurally, not on the message wording: the exact text changed once
# already (packer rejects a message that does not start with a capital), and
# scripts/lint.sh proves the SEMANTICS by checking packer really rejects a bad value.
it "redis_version declares a validation block"
assert_status 0 grep -q 'validation {' "$HCL"

it "whose condition constrains redis_version to maj.min.patch-build"
assert_status 0 grep -qE 'condition.*regex.*var\.redis_version' "$HCL"

it "and whose error message satisfies packer's own rule (capital first, ends in . or ?)"
msg="$(sed -nE 's/^[[:space:]]*error_message[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$HCL" | head -1)"
assert_status 0 grep -qE '^[A-Z].*[.?]$' <<<"$msg"

it "provisioner sources are anchored on path.root, not the CWD (T-08)"
assert_eq "0" "$(grep -cE 'source[[:space:]]+=[[:space:]]+"\.\./' "$HCL")"

it "all three provisioner sources use path.root"
assert_eq "3" "$(grep -cE 'source[[:space:]]+=[[:space:]]+"\$\{path\.root\}/' "$HCL")"

finish
