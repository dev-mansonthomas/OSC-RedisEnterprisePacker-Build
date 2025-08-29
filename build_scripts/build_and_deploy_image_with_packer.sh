#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <aws|outscale> [-debug]"
  exit 1
fi

PROVIDER=$1
shift  # consomme le premier argument (provider)

case "$PROVIDER" in
  aws)
    HCL_FILE=../packer/ubuntu_ufw_aws_image.pkr.hcl
    ;;
  outscale)
    HCL_FILE=../packer/ubuntu_ufw_outscale_image.pkr.hcl
    ;;
  *)
    echo "Erreur: provider inconnu '$PROVIDER' (attendu: aws ou outscale)"
    exit 1
    ;;
esac

MANIFEST_FILE=./manifest.json

# Parse optional -debug flag to enable Packer debug mode
BUILD_OPTS=""
if [[ "${1:-}" == "-debug" ]]; then
  BUILD_OPTS="-debug -on-error=ask"
fi

packer init     $HCL_FILE
packer validate $HCL_FILE
#packer build    -var "region=${REGION}" $BUILD_OPTS $HCL_FILE

# Extract AMI ID from manifest.json
if [[ -f "$MANIFEST_FILE" ]]; then
  AMI_ID=$(jq -r --arg uuid "$(jq -r '.last_run_uuid' "$MANIFEST_FILE")" '.builds[] | select(.packer_run_uuid == $uuid) | .artifact_id' "$MANIFEST_FILE" | cut -d':' -f2)
  echo "AMI_ID=$AMI_ID"
  echo "AMI_ID=$AMI_ID" >> ../_my_env.sh
else
  echo "manifest.json not found. AMI ID not extracted."
fi