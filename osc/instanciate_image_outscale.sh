#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"
pause() {
  read -rp "Press any key to continue..." -n1
  echo    # retour à la ligne après la touche
}
# Valeurs par défaut
SUBNET_IDX=""
MACHINE_TYPE="tinav5.c2r4p3"   # équivalent outscale au t3.xlarge (adapter si besoin)
FLEX_FLAG=""
FLEX_SIZE_GB=""
VOLUME_TYPE="gp2"  # gp2 (SSD), io1 (provisioned IOPS SSD)

usage() {
  cat <<EOF
Usage: $0 --subnet <index> [--machine-type <type>] [--flex <sizeGB>]

Options:
  --subnet <index>        (obligatoire) index du subnet (1, 2, 3)
  --machine-type <type>   (optionnel) type d'instance, défaut: tinav2.c4r8p2
  --flex <sizeGB>         (optionnel) active un second disque "flex" de taille indiquée en Go

Exemples:
  $0 --subnet 1
  $0 --subnet 2 --machine-type tinav2.medium
  $0 --subnet 3 --machine-type tinav2.2xlarge --flex 200
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

# --- Validation des paramètres ---
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

AMI_ID="${OUTSCALE_AMI_ID:-}"

echo "#########################################"
echo "# VM Instance Creation"
echo "#   Subnet index : ${SUBNET_IDX}"
echo "#   Machine type : ${MACHINE_TYPE}"
echo "#   Root device  : /dev/sda1"
echo "#   AMI/OMI ID   : ${AMI_ID}"
if [[ "$FLEX_FLAG" == "flex" ]]; then
  echo "#   Flex volume  : ${FLEX_SIZE_GB} GB (x2 in RAID0)"
else
  echo "#   Flex volume  : none"
fi
echo "#########################################"

KEY_NAME="${KEY_NAME:-}"
SECURITY_GROUP_ID="${SG_ID:-}"
SUBNET_ID_VAR="SUBNET${SUBNET_IDX}"
SUBNET_ID="${!SUBNET_ID_VAR}"
AZ_ID_VAR="AZ${SUBNET_IDX}"
AZ="${!AZ_ID_VAR}"
INSTANCE_NAME="redis-node-${SUBNET_IDX}"

if [[ -z "$AMI_ID" ]]; then echo "Erreur: OUTSCALE_AMI_ID n'est pas défini"; exit 1; fi
if [[ -z "$KEY_NAME" ]]; then echo "Erreur: KEY_NAME n'est pas défini"; exit 1; fi
if [[ -z "$SECURITY_GROUP_ID" ]]; then echo "Erreur: SG_ID n'est pas défini"; exit 1; fi
if [[ -z "$SUBNET_ID" ]]; then echo "Erreur: ${SUBNET_ID_VAR} n'est pas défini"; exit 1; fi

if [[ "$FLEX_FLAG" == "flex" ]]; then
  BLOCK_DEVICE_MAPPINGS="--block-device-mappings \
  DeviceName=/dev/sdf,Ebs={VolumeSize=${FLEX_SIZE_GB},VolumeType=${VOLUME_TYPE},DeleteOnTermination=true} \
  DeviceName=/dev/sdg,Ebs={VolumeSize=${FLEX_SIZE_GB},VolumeType=${VOLUME_TYPE},DeleteOnTermination=true}"
else
  BLOCK_DEVICE_MAPPINGS=""
fi

# Lancer l'instance sur Outscale via le wrapper aws-osc (et non la CLI AWS par défaut)
#--region "$OUTSCALE_REGION" 
#$BLOCK_DEVICE_MAPPINGS \

INSTANCE_ID=$(aws-osc ec2 run-instances \
  --image-id "$OUTSCALE_AMI_ID" \
  --count 1 \
  --instance-type "$MACHINE_TYPE" \
  --key-name "outscale-tmanson-keypair" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --placement "{\"AvailabilityZone\":\"$AZ\", \"Tenancy\":\"default\"}" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
  --security-group-ids "$SG_ID" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# Pause pour laisser le temps à l'IP publique d'être assignée
sleep 5

PUBLIC_IP=$(aws-osc ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$OUTSCALE_REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "Public IP: $PUBLIC_IP"
echo "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ~/.ssh/outscale-tmanson-keypair.rsa outscale@$PUBLIC_IP"

echo "Waiting for instance $INSTANCE_ID to pass status checks..."

get_state_vm=""
filter_json_st='{"VmIds":["'"$INSTANCE_ID"'"]}'
until [ "$get_state_vm" = "running" ] ; do
  sleep 10
  echo "[INFO][5s] - Waiting Vm ..."
  get_state_vm=$(oapi-cli ReadVmsState --Filters "$filter_json_st" \
                 | jq -r '.VmStates[].VmState')
  echo "Instance $INSTANCE_ID is '$get_state_vm'"
done
echo "Instance $INSTANCE_ID is now running."


BOOT_VOL_ID=$(
  oapi-cli ReadVms --Filters "{\"VmIds\":[\"${INSTANCE_ID}\"]}" \
  | jq -r '.Vms[0].BlockDeviceMappings[]
           | select(.DeviceName == "/dev/sda1")
           | .Bsu.VolumeId'
)

if [[ -z "$BOOT_VOL_ID" || "$BOOT_VOL_ID" == "null" ]]; then
  echo "Impossible de trouver le volume root (/dev/sda1) pour $INSTANCE_ID" >&2
  exit 1
fi

echo "Volume racine: $BOOT_VOL_ID"

app="redis-"
name="01"
tag="[$app][$name]"
echo "Tagging instance as $tag"

# Construire le JSON des tags et l’appliquer
TAGS_JSON=$(jq -n --arg name "$INSTANCE_NAME" "[{Key:\"Name\", Value:\"$tag\"}]")
echo "Tags JSON: $TAGS_JSON"
set +x
oapi-cli CreateTags \
  --ResourceIds "[\"${BOOT_VOL_ID}\"]" \
  --Tags "$TAGS_JSON"

echo "Sleeping 30 seconds to let the instance initialize..."
sleep 30

# On sauvegarde aussi l'IP et l'ID dans ton _my_env.sh
echo -e "OUTSCALE_INSTANCE_PUBLIC_IP_${SUBNET_IDX}=${PUBLIC_IP} #${INSTANCE_ID}" >> "$(dirname "$0")/../_my_env.sh"