#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# _my_env.sh is operator-supplied and git-ignored: shellcheck cannot follow it.
# shellcheck source=/dev/null
source "$REPO_ROOT/_my_env.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/redis_version.sh
source "$REPO_ROOT/build_scripts/lib/redis_version.sh"

# Absolute paths throughout: the script used to depend on being run from
# build_scripts/ (TODO T-08).
HCL_FILE="$REPO_ROOT/packer/redis_ubuntu_outscale_image.pkr.hcl"
TARGET_REGION="$OUTSCALE_REGION"
MANIFEST_FILE="$REPO_ROOT/build_scripts/manifest.json"

# --- Redis Enterprise tarball: pre-flight ---
# Delegated to fetch_redis_tarball.sh, which (unlike the inline `ls | head -1` this
# replaces) refuses to guess between several tarballs and detects a filename that
# carries no usable version instead of silently mis-parsing it (TODO T-05).
# Set FETCH_OPTS=--download to fetch the latest, or --skip-version-check to stay offline.
: "${FETCH_OPTS:=}"
# shellcheck disable=SC2086  # FETCH_OPTS is a deliberate option list
PREFLIGHT="$("$REPO_ROOT/build_scripts/fetch_redis_tarball.sh" $FETCH_OPTS)" || exit 1
printf '%s\n' "$PREFLIGHT"

REDIS_VERSION="$(printf '%s' "$PREFLIGHT" | sed -n 's/^REDIS_VERSION=//p' | tail -1)"
if ! rcv_is_valid_version "$REDIS_VERSION"; then
  echo "Erreur : version Redis Enterprise invalide ou absente ('$REDIS_VERSION')" >&2
  exit 1
fi

export PKR_VAR_redis_version="$REDIS_VERSION"
echo "REDIS_VERSION : '$REDIS_VERSION'"
echo "Attendu par Packer: redis-software/$(rcv_tarball_name "$REDIS_VERSION")"

# Parse optional -debug flag to enable Packer debug mode
BUILD_OPTS=()
if [[ "${1:-}" == "-debug" ]]; then
  BUILD_OPTS=(-debug -on-error=ask)
fi



# The manifest post-processor writes relative to the CWD, and the HCL's file
# provisioners use ../ paths, so keep packer anchored in build_scripts/.
cd "$REPO_ROOT/build_scripts"

packer init     "$HCL_FILE"
packer validate "$HCL_FILE"


# juste avant packer build
args=(
  -var "region=${TARGET_REGION}"
  -var "keypair_private_file=${OUTSCALE_SSH_KEY}"
  -var "redis_version=${REDIS_VERSION}"
)
# optionnel: si BUILD_OPTS n'est pas vide, on l’ajoute proprement
(( ${#BUILD_OPTS[@]} )) && args+=("${BUILD_OPTS[@]}")

set -x  # pour voir exactement les args passés
PACKER_LOG=1 PACKER_LOG_PATH=packer.out \
  packer build "${args[@]}" "$HCL_FILE"
set +x

# Extract AMI ID from manifest.json
if [[ -f "$MANIFEST_FILE" ]]; then
  AMI_ID=$(jq -r --arg uuid "$(jq -r '.last_run_uuid' "$MANIFEST_FILE")" '.builds[] | select(.packer_run_uuid == $uuid) | .artifact_id' "$MANIFEST_FILE" | cut -d':' -f2)
  echo "OUTSCALE_AMI_ID for Outscale in region $TARGET_REGION: $AMI_ID"
  echo -e "\nOUTSCALE_AMI_ID=$AMI_ID" >> ../_my_env.sh  
else
  echo "manifest.json not found. AMI ID not extracted."
fi