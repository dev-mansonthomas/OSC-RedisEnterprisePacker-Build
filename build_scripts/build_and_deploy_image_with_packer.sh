#!/usr/bin/env bash

HCL_FILE=../packer/ubuntu_ufw_aws_image.pkr.hcl
MANIFEST_FILE=./manifest.json

# Parse optional -debug flag to enable Packer debug mode
BUILD_OPTS=""
if [[ "${1:-}" == "-debug" ]]; then
  BUILD_OPTS="-debug -on-error=ask"
fi

packer init     $HCL_FILE
packer validate $HCL_FILE
packer build    $BUILD_OPTS $HCL_FILE

# Extract AMI ID from manifest.json
if [[ -f "$MANIFEST_FILE" ]]; then
  AMI_ID=$(jq -r --arg uuid "$(jq -r '.last_run_uuid' "$MANIFEST_FILE")" '.builds[] | select(.packer_run_uuid == $uuid) | .artifact_id' "$MANIFEST_FILE" | cut -d':' -f2)
  echo "AMI_ID=$AMI_ID"
  echo "AMI_ID=$AMI_ID" >> ../_my_env.sh
else
  echo "manifest.json not found. AMI ID not extracted."
fi