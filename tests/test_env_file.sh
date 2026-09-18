#!/usr/bin/env bash
# _my_env.sh is the interface between osc-setup.sh, the build wrapper and the Run
# repo. Append-only writes used to leave conflicting blocks, and a stale
# OUTSCALE_AMI_ID launches the wrong image (T-01). These tests pin the rewrite.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
source "$(dirname "$0")/../build_scripts/lib/env_file.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
F="$TMP/_my_env.sh"

seed() { printf 'OWNER="thomas-manson"\nOUTSCALE_REGION=eu-west-2\n' > "$F"; }

# ---------- first write ----------
seed
env_write_block "$F" outscale-net "OSC_NET_ID=vpc-111" "OSC_SG_ID=sg-111"

it "preserves the operator's own configuration"
assert_contains "$(cat "$F")" 'OWNER="thomas-manson"'

it "writes the block body"
assert_contains "$(cat "$F")" "OSC_NET_ID=vpc-111"

it "reads the block back"
assert_eq "OSC_NET_ID=vpc-111
OSC_SG_ID=sg-111" "$(env_read_block "$F" outscale-net)"

# ---------- rewrite: the T-01 regression ----------
env_write_block "$F" outscale-net "OSC_NET_ID=vpc-222" "OSC_SG_ID=sg-222"

it "REPLACES the block instead of appending a second one"
assert_eq "1" "$(env_legacy_duplicates "$F" OSC_NET_ID)"

it "keeps only the new value"
assert_contains "$(cat "$F")" "OSC_NET_ID=vpc-222"

it "and drops the old one entirely"
assert_eq "0" "$(grep -c 'vpc-111' "$F" || true)"

it "stays idempotent across repeated identical writes"
env_write_block "$F" outscale-net "OSC_NET_ID=vpc-222" "OSC_SG_ID=sg-222"
before="$(cat "$F")"
env_write_block "$F" outscale-net "OSC_NET_ID=vpc-222" "OSC_SG_ID=sg-222"
assert_eq "$before" "$(cat "$F")"

# ---------- independent blocks ----------
env_write_block "$F" outscale-omi "OUTSCALE_AMI_ID=ami-aaa"

it "a second block does not disturb the first"
assert_contains "$(env_read_block "$F" outscale-net)" "OSC_NET_ID=vpc-222"

it "and is readable on its own"
assert_eq "OUTSCALE_AMI_ID=ami-aaa" "$(env_read_block "$F" outscale-omi)"

it "rewriting one block leaves the other intact"
env_write_block "$F" outscale-omi "OUTSCALE_AMI_ID=ami-bbb"
assert_contains "$(env_read_block "$F" outscale-net)" "OSC_SG_ID=sg-222"

it "and the rewritten block has exactly one value"
assert_eq "1" "$(env_legacy_duplicates "$F" OUTSCALE_AMI_ID)"

# ---------- the file stays sourceable, which is the whole point ----------
it "the result is valid shell"
assert_status 0 bash -n "$F"

it "and sourcing it yields the latest values"
out="$(bash -c "source '$F'; echo \"\$OSC_NET_ID \$OUTSCALE_AMI_ID \$OWNER\"")"
assert_eq "vpc-222 ami-bbb thomas-manson" "$out"

# ---------- legacy detection ----------
it "counts the duplicate assignments left by the old append-only scripts"
printf 'OSC_NET_ID=vpc-old1\nOSC_NET_ID=vpc-old2\n' >> "$F"
assert_eq "3" "$(env_legacy_duplicates "$F" OSC_NET_ID)"

# ---------- writing into a file that does not exist yet ----------
it "creates the env file when absent"
rm -f "$F"
env_write_block "$F" outscale-omi "OUTSCALE_AMI_ID=ami-ccc"
assert_eq "OUTSCALE_AMI_ID=ami-ccc" "$(env_read_block "$F" outscale-omi)"

finish
