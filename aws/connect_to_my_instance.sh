#!/usr/bin/env bash

SUBNET_IDX=$1
if [[ -z "$SUBNET_IDX" ]]; then
  echo "Usage: $0 <subnet_index>"
  exit 1
fi

source "$(dirname "$0")/../_my_env.sh"

PUBLIC_IP_VAR="INSTANCE_PUBLIC_IP_${SUBNET_IDX}"
PUBLIC_IP="${!PUBLIC_IP_VAR}"

if [[ -z "$PUBLIC_IP" ]]; then
  echo "Error: No public IP found for $PUBLIC_IP_VAR"
  exit 1
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/id_ed25519 ubuntu@"$PUBLIC_IP"
