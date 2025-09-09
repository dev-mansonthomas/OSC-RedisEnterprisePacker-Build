#!/usr/bin/env bash
set -euo pipefail

# Charge les variables (_my_env.sh doit contenir OUTSCALE_AMI_ID, OUTSCALE_REGION, KEY_NAME, SG_ID, SUBNET1..3, etc.)
source "$(dirname "$0")/../_my_env.sh"

# Valeurs par défaut (adapter le VmType Outscale)
SUBNET_IDX=""
MACHINE_TYPE="tinav5.c2r16p3"     # ex: 2 vCPU / 16 GiB comme dans ta capture
FLEX_FLAG=""
FLEX_SIZE_GB=""

usage() {
  cat <<EOF
Usage: $0 --subnet <index> [--machine-type <type>] [--flex <sizeGB>]

Options:
  --subnet <index>        (obligatoire) index du subnet (1, 2, 3)
  --machine-type <type>   (optionnel) Outscale VmType (ex: tinav5.c2r16p3). Défaut: ${MACHINE_TYPE}
  --flex <sizeGB>         (optionnel) ajoute 2 volumes BSU de <sizeGB> Go (RAID0 ensuite côté VM)

Exemples:
  $0 --subnet 1
  $0 --subnet 2 --machine-type tinav5.c4r16p2
  $0 --subnet 3 --machine-type tinav5.c2r16p3 --flex 200
EOF
}

# --- Parsing des arguments nommés ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subnet)
      SUBNET_IDX="${2:-}"; shift 2 ;;
    --machine-type)
      MACHINE_TYPE="${2:-}"; shift 2 ;;
    --flex)
      FLEX_FLAG="flex"
      FLEX_SIZE_GB="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Argument inconnu: $1"; usage; exit 1 ;;
  esac
done

# Validation des paramètres
if [[ -z "${SUBNET_IDX}" ]]; then
  echo "Erreur: --subnet <index> est obligatoire."; usage; exit 1
fi
if [[ "${FLEX_FLAG:-}" == "flex" && -z "${FLEX_SIZE_GB:-}" ]]; then
  echo "Erreur: --flex nécessite une taille (Go)."; usage; exit 1
fi

# Variables d'env requises (depuis _my_env.sh)
: "${OUTSCALE_AMI_ID:?OUTSCALE_AMI_ID manquant dans _my_env.sh}"
: "${OUTSCALE_REGION:?OUTSCALE_REGION manquant dans _my_env.sh}"
: "${KEY_NAME:?KEY_NAME manquant dans _my_env.sh}"
: "${SG_ID:?SG_ID manquant dans _my_env.sh}"

SUBNET_ID_VAR="SUBNET${SUBNET_IDX}"
SUBNET_ID="${!SUBNET_ID_VAR:-}"
if [[ -z "${SUBNET_ID}" ]]; then
  echo "Erreur: ${SUBNET_ID_VAR} manquant dans _my_env.sh"; exit 1
fi

INSTANCE_NAME="redis-node-${SUBNET_IDX}"

# Construction du BlockDeviceMappings pour --flex
BDM_JSON="[]"
if [[ "${FLEX_FLAG:-}" == "flex" ]]; then
  # Deux volumes gp2, DeleteOnVmDeletion=true
  # DeviceName indicatif : l'OS les exposera en /dev/nvme* (normal sur Outscale/AWS).
  BDM_JSON=$(
    jq -nc --arg size "${FLEX_SIZE_GB}" '
      [
        { "DeviceName": "/dev/sdf",
          "Bsu": { "VolumeSize": ($size|tonumber), "VolumeType": "gp2", "DeleteOnVmDeletion": true } },
        { "DeviceName": "/dev/sdg",
          "Bsu": { "VolumeSize": ($size|tonumber), "VolumeType": "gp2", "DeleteOnVmDeletion": true } }
      ]'
  )
fi

echo "Lancement VM Outscale:"
echo "- ImageId (OMI):   ${OUTSCALE_AMI_ID}"
echo "- VmType:          ${MACHINE_TYPE}"
echo "- KeypairName:     ${KEY_NAME}"
echo "- SecurityGroupId: ${SG_ID}"
echo "- SubnetId:        ${SUBNET_ID}"
echo "- Region:          ${OUTSCALE_REGION}"
[[ "${FLEX_FLAG:-}" == "flex" ]] && echo "- Flex:            2x${FLEX_SIZE_GB} Go (gp2)"

# RunInstances
# Remarques :
# - MapPublicIpOnLaunch doit être activé sur le Subnet (sinon, il faudra lier une IP publique ensuite).
# - SecurityGroupIds s'attend à un tableau JSON.
# - TagSpecification: on tag l'instance avec Name=${INSTANCE_NAME}

echo "=== Commande RunInstances générée ==="
echo oapi-cli RunInstances --ImageId ami-f826b70f \
  --VmType tinav5.c2r16p3 \
  --KeypairName tmanson-aws-key \
  --SubnetId subnet-4e6a5de7 \
  --SecurityGroupIds '["sg-69085d84"]' \
  --BlockDeviceMappings '[{"DeviceName":"/dev/sdf","Bsu":{"VolumeSize":10,"VolumeType":"gp2","DeleteOnVmDeletion":true}},{"DeviceName":"/dev/sdg","Bsu":{"VolumeSize":10,"VolumeType":"gp2","DeleteOnVmDeletion":true}}]' \
  --MinCount 1 \
  --MaxCount 1 \
  --TagSpecifications '[{"ResourceType":"vm","Tags":[{"Key":"Name","Value":"redis-node-1"}]}]'
echo "====================================="

VM_JSON="$(
  oapi-cli RunInstances \
    --ImageId "${OUTSCALE_AMI_ID}" \
    --VmType "${MACHINE_TYPE}" \
    --KeypairName "${KEY_NAME}" \
    --SubnetId "${SUBNET_ID}" \
    --SecurityGroupIds '"[\"${SG_ID}\"]"' \
    --BlockDeviceMappings '"${BDM_JSON}"' \
    --MinCount 1 \
    --MaxCount 1 \
    --TagSpecifications '"[{\"ResourceType\":\"vm\",\"Tags\":[{\"Key\":\"Name\",\"Value\":\"${INSTANCE_NAME}\"}]}]"'
)"

VM_ID="$(echo "${VM_JSON}" | jq -r '.Vms[0].VmId')"
if [[ -z "${VM_ID}" || "${VM_ID}" == "null" ]]; then
  echo "Echec RunInstances, réponse:" >&2
  echo "${VM_JSON}" >&2
  exit 1
fi
echo "Instance ID: ${VM_ID}"

# Attendre que la VM soit 'running' puis qu'une IP publique soit présente
echo "Attente démarrage + IP publique…"
PUBLIC_IP=""
for i in {1..60}; do
  sleep 5
  READ_JSON="$(oapi-cli ReadVms --Filters "{\"VmIds\":[\"${VM_ID}\"]}")"
  STATE="$(echo "${READ_JSON}" | jq -r '.Vms[0].State // empty')"
  PUBLIC_IP="$(echo "${READ_JSON}" | jq -r '.Vms[0].PublicIp // empty')"
  echo "  try #$i: state=${STATE:-?} public_ip=${PUBLIC_IP:-none}"
  [[ "${STATE}" == "running" && -n "${PUBLIC_IP}" && "${PUBLIC_IP}" != "null" ]] && break
done

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "null" ]]; then
  echo "Impossible de récupérer l'IP publique (après timeout). Réponse:" >&2
  echo "${READ_JSON}" >&2
  exit 1
fi

echo "Public IP: ${PUBLIC_IP}"
echo "ssh -i ~/.ssh/outscale-tmanson-keypair.rsa outscale@${PUBLIC_IP}"

# Optionnel: attendre les "status checks" côté hyperviseur: pas d'équivalent direct "wait" comme AWS CLI,
# on boucle jusqu'à running + ping SSH si besoin.
echo "Test SSH… (5 essais max)"
for i in {1..5}; do
  sleep 5
  if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 -i ~/.ssh/outscale-tmanson-keypair.rsa \
        outscale@"${PUBLIC_IP}" "echo ok" >/dev/null 2>&1; then
    echo "SSH OK."
    break
  fi
  echo "  ssh try #$i failed…"
done

# Copie du script de cluster (utilisateur 'outscale' par défaut sur Outscale Ubuntu)
# Adapte le chemin de clé privée si besoin
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/outscale-tmanson-keypair.rsa \
    ../image_scripts/create-or-join-redis-cluster.sh \
    outscale@"${PUBLIC_IP}":/home/outscale/create-or-join-redis-cluster.sh

# Sauvegarde dans _my_env.sh pour réutilisation
echo -e "OUTSCALE_INSTANCE_PUBLIC_IP_${SUBNET_IDX}=${PUBLIC_IP} #${VM_ID}" >> "$(dirname "$0")/../_my_env.sh"