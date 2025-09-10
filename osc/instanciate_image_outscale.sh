#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"
pause() {
  read -rp "Press any key to continue..." -n1
  echo    # retour à la ligne après la touche
}
# Valeurs par défaut
SUBNET_IDX=""
MACHINE_TYPE="tinav5.c2r4p3"    # specific machine type to outscale
FLEX_FLAG="flex"                # set to "" if you don't want flex
FLEX_SIZE_GB="40"               # 2 volumes in RAID0 of this size will be provisionned if FLEX_FLAG is set
VOLUME_TYPE="io1"               # gp2 (SSD), io1 (provisioned IOPS SSD)
FLEX_IOPS="${FLEX_IOPS:-1000}"  # IOPS per volume for io1 (min 100, max 64000 for AWS, 20000 for outscale, ratio 50 IOPS/GB) 

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
  echo "#   Flex volumes : 2 x ${FLEX_SIZE_GB} GiB (type=${VOLUME_TYPE}, IOPS=${FLEX_IOPS})"
else
  echo "#   Flex volumes : none"
fi
echo "#########################################"

KEY_NAME="${KEY_NAME:-}"
SECURITY_GROUP_ID="${SG_ID:-}"
SUBNET_ID_VAR="SUBNET${SUBNET_IDX}"
SUBNET_ID="${!SUBNET_ID_VAR}"
AZ_ID_VAR="AZ${SUBNET_IDX}"
AZ="${!AZ_ID_VAR}"
INSTANCE_NAME="redis-node-${SUBNET_IDX}"
OAPI_PROFILE="default"

if [[ -z "$AMI_ID"            ]]; then echo "Erreur: OUTSCALE_AMI_ID n'est pas défini";     exit 1; fi
if [[ -z "$KEY_NAME"          ]]; then echo "Erreur: KEY_NAME n'est pas défini";            exit 1; fi
if [[ -z "$SECURITY_GROUP_ID" ]]; then echo "Erreur: SG_ID n'est pas défini";               exit 1; fi
if [[ -z "$SUBNET_ID"         ]]; then echo "Erreur: ${SUBNET_ID_VAR} n'est pas défini";    exit 1; fi

# --- BlockDeviceMappings (FLEX -> 2 volumes io1) ---
BDM_JSON="[]"
if [[ "$FLEX_FLAG" == "flex" ]]; then
  # NOTE: io1 requiert un champ "Iops". Ajuste FLEX_IOPS selon la taille/perf souhaitée.
  BDM_JSON="$(
    jq -nc --arg size "$FLEX_SIZE_GB" --arg iops "$FLEX_IOPS" '
      [
        {
          "DeviceName": "/dev/sdf",
          "Bsu": {
            "VolumeSize": ($size|tonumber),
            "VolumeType": "io1",
            "Iops": ($iops|tonumber),
            "DeleteOnVmDeletion": true
          }
        },
        {
          "DeviceName": "/dev/sdg",
          "Bsu": {
            "VolumeSize": ($size|tonumber),
            "VolumeType": "io1",
            "Iops": ($iops|tonumber),
            "DeleteOnVmDeletion": true
          }
        }
      ]'
  )"
fi

echo "BlockDeviceMappings: $BDM_JSON"


VM_JSON=$(oapi-cli --profile "$OAPI_PROFILE" CreateVms \
  --ImageId "$OUTSCALE_AMI_ID" \
  --VmType "$MACHINE_TYPE" \
  --KeypairName "outscale-tmanson-keypair" \
  --SubnetId "$SUBNET_ID" \
  --Placement '{"Tenancy":"default","SubregionName":"'"$AZ"'"}' \
  --SecurityGroupIds '["'"$SG_ID"'"]' \
  --BlockDeviceMappings "$BDM_JSON"
)

echo "VM JSON Response: 
##########################
$VM_JSON
##########################
"

INSTANCE_ID=$(echo "$VM_JSON" | jq -r '.Vms[0].VmId')
echo "Instance ID: $INSTANCE_ID"

PUBLIC_IP=$(echo "$VM_JSON" | jq -r '.Vms[0].PublicIp')


echo "Allocated Public IP: $PUBLIC_IP"
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


# Ex: taguer les volumes de la VM
oapi-cli --profile "$OAPI_PROFILE" CreateTags \
    --ResourceIds '["'"$INSTANCE_ID"'"]' \
    --Tags '[{"Key":"Name","Value":"'"$INSTANCE_NAME"'"}]'


echo "Sleeping 30 seconds to let the instance initialize..."
sleep 30

# On sauvegarde aussi l'IP et l'ID dans ton _my_env.sh
echo -e "OUTSCALE_INSTANCE_PUBLIC_IP_${SUBNET_IDX}=${PUBLIC_IP} #${INSTANCE_ID}" >> "$(dirname "$0")/../_my_env.sh"