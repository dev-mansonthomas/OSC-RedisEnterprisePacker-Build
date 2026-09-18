#!/usr/bin/env bash
# The build refuses to start when the target region has no base-OMI mapping, so the
# failure is a clear message instead of an empty source_omi reaching Packer (T-10).
# This pins the check against the REAL HCL, which is the part that can silently rot.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
HCL="$(cd "$(dirname "$0")/.." && pwd)/packer/redis_ubuntu_outscale_image.pkr.hcl"

# The predicate as used by build_and_deploy_redis_image_with_packer.sh
region_is_mapped() { grep -qE "\"${1}\"[[:space:]]*=" "$HCL"; }

# The region -> OMI map was removed: Outscale republishes Ubuntu 22.04 every ~2 months
# and prunes old images after ~10, so any ID committed here expires. The wrapper now
# resolves the newest image at build time, or honours an explicit pin.
it "no OMI id is hardcoded as a value anywhere in the template"
assert_eq "0" "$(grep -cE '=[[:space:]]*"ami-[0-9a-f]+"' "$HCL")"

it "the deregistered ami-054f16b1 is not pinned"
assert_status 1 grep -qE '=[[:space:]]*"ami-054f16b1"' "$HCL"

it "source_omi is a variable fed by the wrapper"
assert_status 0 grep -q 'variable "source_omi"' "$HCL"

it "and the source block consumes it"
assert_status 0 grep -qE 'source_omi[[:space:]]+=[[:space:]]+var\.source_omi' "$HCL"

it "the base image is recorded in the tags, so a published OMI is traceable"
assert_status 0 grep -q 'SourceOMI' "$HCL"

it "and in the image description"
assert_status 0 grep -q 'base \${var.source_omi}' "$HCL"

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
