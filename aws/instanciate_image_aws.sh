#!/usr/bin/env bash
source "$(dirname "$0")/../_my_env.sh"


# Valeurs par défaut
SUBNET_IDX=""
MACHINE_TYPE="t3.xlarge"
FLEX_FLAG=""
FLEX_SIZE_GB=""

usage() {
  cat <<EOF
Usage: $0 --subnet <index> [--machine-type <type>] [--flex <sizeGB>]

Options:
  --subnet <index>        (obligatoire) index du subnet (1, 2, 3)
  --machine-type <type>   (optionnel) type d'instance, défaut: t3.xlarge
  --flex <sizeGB>         (optionnel) active mode "flex" avec taille disque en Go

Exemples:
  $0 --subnet 1
  $0 --subnet 2 --machine-type t3.large
  $0 --subnet 3 --machine-type m5.xlarge --flex 200
EOF
}

# --- Parsing des arguments nommés ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subnet)
      SUBNET_IDX="$2"
      shift 2
      ;;
    --machine-type)
      MACHINE_TYPE="$2"
      shift 2
      ;;
    --flex)
      FLEX_FLAG="flex"
      FLEX_SIZE_GB="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Argument inconnu: $1"
      usage
      exit 1
      ;;
  esac
done

# Validation des paramètres
if [[ -z "$SUBNET_IDX" ]]; then
  echo "Erreur: --subnet <index> est obligatoire."
  usage
  exit 1
fi

if [[ "$FLEX_FLAG" == "flex" && -z "$FLEX_SIZE_GB" ]]; then
  echo "Erreur: --flex nécessite une taille (Go)."
  usage
  exit 1
fi
set -euo pipefail

AMI_ID="${AMI_ID}"
KEY_NAME="${KEY_NAME}"
SECURITY_GROUP_ID="${SG_ID}"
SUBNET_ID_VAR="SUBNET${SUBNET_IDX}"
SUBNET_ID="${!SUBNET_ID_VAR}"
INSTANCE_NAME="redis-node-${SUBNET_IDX}"


if [[ -z "$AMI_ID" ]]; then echo "AMI_ID is not set"; exit 1; fi
if [[ -z "$KEY_NAME" ]]; then echo "KEY_NAME is not set"; exit 1; fi
if [[ -z "$SECURITY_GROUP_ID" ]]; then echo "SECURITY_GROUP_ID is not set"; exit 1; fi
if [[ -z "$SUBNET_ID" ]]; then echo "${SUBNET_ID_VAR} is not set"; exit 1; fi


if [[ "$FLEX_FLAG" == "flex" ]]; then
  BLOCK_DEVICE_MAPPINGS="--block-device-mappings \
  DeviceName=/dev/sdf,Ebs={VolumeSize=${FLEX_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true} \
  DeviceName=/dev/sdg,Ebs={VolumeSize=${FLEX_SIZE_GB},VolumeType=gp3,DeleteOnTermination=true}"
else
  BLOCK_DEVICE_MAPPINGS=""
fi

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --count 1 \
  --instance-type "$MACHINE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids "$SECURITY_GROUP_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --region $REGION \
  $BLOCK_DEVICE_MAPPINGS \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for the public IP to be assigned
sleep 5

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"
echo "ssh -i ~/.ssh/id_ed25519 ubuntu@$PUBLIC_IP"

# Wait for the instance to enter the 'running' state
echo "Waiting for instance $INSTANCE_ID to pass status checks..."
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"
echo "Instance $INSTANCE_ID is now running."

scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/id_ed25519  ../image_scripts/create-or-join-redis-cluster.sh ubuntu@$PUBLIC_IP:/home/ubuntu/create-or-join-redis-cluster.sh

echo -e "INSTANCE_PUBLIC_IP_${SUBNET_IDX}=${PUBLIC_IP} #${INSTANCE_ID}" >> "$(dirname "$0")/../_my_env.sh"
