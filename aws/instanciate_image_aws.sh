#!/usr/bin/env bash
source "$(dirname "$0")/../_my_env.sh"


SUBNET_IDX="$1"
MACHINE_TYPE="$2"

if [[ -z "$MACHINE_TYPE" ]]; then
  MACHINE_TYPE="t3.xlarge"
fi

if [[ -z "$SUBNET_IDX" ]]; then
  echo "Usage: $0 <subnet-index>"
  exit 1
fi

AMI_ID="${AMI_ID}"
KEY_NAME="${KEY_NAME}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID}"
SUBNET_ID_VAR="SUBNET${SUBNET_IDX}"
SUBNET_ID="${!SUBNET_ID_VAR}"
INSTANCE_NAME="redis-node-${SUBNET_IDX}"

if [[ -z "$AMI_ID" ]]; then echo "AMI_ID is not set"; exit 1; fi
if [[ -z "$KEY_NAME" ]]; then echo "KEY_NAME is not set"; exit 1; fi
if [[ -z "$SECURITY_GROUP_ID" ]]; then echo "SECURITY_GROUP_ID is not set"; exit 1; fi
if [[ -z "$SUBNET_ID" ]]; then echo "${SUBNET_ID_VAR} is not set"; exit 1; fi

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$MACHINE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --region eu-west-3 \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for the public IP to be assigned
sleep 5

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region eu-west-3 \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"
echo "ssh -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP"

echo "INSTANCE_PUBLIC_IP_${SUBNET_IDX}=${PUBLIC_IP}" >> "$(dirname "$0")/../_my_env.sh"
