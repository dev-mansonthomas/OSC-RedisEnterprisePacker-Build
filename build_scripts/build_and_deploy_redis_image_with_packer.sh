#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"

HCL_FILE=../packer/redis_ubuntu_outscale_image.pkr.hcl
TARGET_REGION="$OUTSCALE_REGION"
MANIFEST_FILE=./manifest.json

FILE=$(ls ../redis-software/redislabs-*.tar 2>/dev/null | head -n 1)

if [ -z "$FILE" ]; then
  echo "Erreur : aucun fichier redislabs-*.tar trouvé dans ../redis-software/"
  return 1 2>/dev/null || exit 1
fi

REDIS_VERSION=$(basename "$FILE" | sed -E 's/^redislabs-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*/\1/')

# Vérifier que l’extraction a réussi
if [ -z "$REDIS_VERSION" ]; then
  echo "Erreur : impossible d’extraire la version depuis $FILE"
  return 1 2>/dev/null || exit 1
fi

REDIS_VERSION=${REDIS_VERSION%%[$'\r\n']*}
export PKR_VAR_redis_version="$REDIS_VERSION"
echo "REDIS_VERSION : '$REDIS_VERSION'"
echo "Attendu par Packer: ../redis-software/redislabs-${REDIS_VERSION}-jammy-amd64.tar"

# Parse optional -debug flag to enable Packer debug mode
BUILD_OPTS=""
if [[ "${1:-}" == "-debug" ]]; then
  BUILD_OPTS="-debug -on-error=ask"
fi



packer init     $HCL_FILE
packer validate $HCL_FILE


# juste avant packer build
args=(
  -var "region=${TARGET_REGION}"
  -var "keypair_private_file=${OUTSCALE_SSH_KEY}"
  -var "redis_version=${REDIS_VERSION}"
)
# optionnel: si BUILD_OPTS n'est pas vide, on l’ajoute proprement
[[ -n "${BUILD_OPTS:-}" ]] && args+=($BUILD_OPTS)

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