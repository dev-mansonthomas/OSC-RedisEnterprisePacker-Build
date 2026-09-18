# shellcheck shell=bash
# Copy this file to _my_env.sh and fill in the values below.
# _my_env.sh is git-ignored and is the interface between osc-setup.sh, the build
# wrapper and the OSC-RedisEnterprisePacker-Run repo.

# --- Operator configuration: yours to edit ---
OWNER="thomas-manson"
OUTSCALE_REGION=eu-west-2
OUTSCALE_SSH_KEY="$HOME/.ssh/outscale-tmanson-keypair.rsa"
# Name of the Outscale keypair to inject into build VMs. Defaults to
# outscale-tmanson-keypair when unset.
#OUTSCALE_KEYPAIR_NAME="outscale-tmanson-keypair"

# --- Generated: do not edit by hand ---
# The scripts append nothing: they rewrite delimited blocks in place, so re-running
# them updates the values instead of stacking a second, shadowing copy.
#
#   # >>> generated: outscale-net >>>     written by osc/osc-setup.sh
#   OSC_NET_ID / OSC_IGW_ID / OSC_RTB_ID / OSC_SG_ID
#   OSC_SUBNET1..3 / OSC_AZ1..3
#   # <<< generated: outscale-net <<<
#
#   # >>> generated: outscale-omi >>>     written by build_scripts/build_and_deploy_redis_image_with_packer.sh
#   OUTSCALE_AMI_ID
#   # <<< generated: outscale-omi <<<
#
# If you see the same key assigned more than once, the extra lines are leftovers from
# the old append-only behaviour: delete the ones outside the blocks. The scripts warn
# when they detect this, because a stale OUTSCALE_AMI_ID launches the wrong image.
