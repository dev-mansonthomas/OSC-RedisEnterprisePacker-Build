#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"

pause() {
  read -rp "Press any key to continue..." -n1
  echo    # retour à la ligne après la touche
}

# --- Vérifs variables d'env attendues ---
: "${OUTSCALE_AMI_ID:?Error: OUTSCALE_AMI_ID is not set in _my_env.sh. Please build the OMI first.}"
: "${OUTSCALE_REGION:?Error: OUTSCALE_REGION is not set in _my_env.sh.}"
: "${OUTSCALE_CLUSTER_DNS:?Error: OUTSCALE_CLUSTER_DNS is not set in _my_env.sh.}"

# Optionnel: chemin de clé privée SSH (par défaut)
SSH_KEY="${OUTSCALE_SSH_KEY:?Error: OUTSCALE_SSH_KEY is not set in _my_env.sh.}"

# --- Paramètres "infra" ---
FLEX_FLAG="flex"          # mettre "" si tu ne veux pas de flex
FLEX_SIZE_GB="10"        # taille de CHAQUE volume; RAID0 => taille totale = 2x
MACHINE_TYPE="tinav5.c2r16p3"  # remplace si besoin

# --- Commande flash (si flex) ---
FLE_CMD=""
if [[ "$FLEX_FLAG" == "flex" ]]; then
  FLE_CMD="sudo /opt/redislabs/sbin/prepare_flash.sh"
fi

cluster_dns="$OUTSCALE_CLUSTER_DNS"
RS_admin="$REDIS_LOGIN"
RS_password="$REDIS_PWD"
mode="init"
zone="$AZ1"

# ========== Noeud 1 ==========
./instanciate_image_outscale.sh --subnet 1 --machine-type "$MACHINE_TYPE" ${FLEX_FLAG:+--flex "$FLEX_SIZE_GB"}
source "$(dirname "$0")/../_my_env.sh"

IP1_VAR="OUTSCALE_INSTANCE_PUBLIC_IP_1"
INSTANCE_PUBLIC_IP_1="${!IP1_VAR:?$IP1_VAR not set (instanciate step failed?)}"

pause

echo "Connecting to $INSTANCE_PUBLIC_IP_1 to configure cluster (node 1)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null outscale@"${INSTANCE_PUBLIC_IP_1}" << EOF
  ${FLE_CMD:-true}
  chmod 700 /home/outscale/create-or-join-redis-cluster.sh
  sudo /home/outscale/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$INSTANCE_PUBLIC_IP_1" "$zone" 1
EOF

echo "sleep 30 seconds to let the cluster initialize..."
sleep 30

# ========== Noeud 2 ==========
mode="join"
master_ip="$INSTANCE_PUBLIC_IP_1"

./instanciate_image_outscale.sh --subnet 2 --machine-type "$MACHINE_TYPE" ${FLEX_FLAG:+--flex "$FLEX_SIZE_GB"}
source "$(dirname "$0")/../_my_env.sh"

zone="$AZ2"
IP2_VAR="OUTSCALE_INSTANCE_PUBLIC_IP_2"
INSTANCE_PUBLIC_IP_2="${!IP2_VAR:?$IP2_VAR not set (instanciate step failed?)}"

echo "Connecting to $INSTANCE_PUBLIC_IP_2 to configure cluster (node 2)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null outscale@"${INSTANCE_PUBLIC_IP_2}" << EOF
  ${FLE_CMD:-true}
  chmod 700 /home/outscale/create-or-join-redis-cluster.sh
  sudo /home/outscale/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "${INSTANCE_PUBLIC_IP_2}" "$zone" 2 "$master_ip"
EOF

# ========== Noeud 3 ==========
./instanciate_image_outscale.sh --subnet 3 --machine-type "$MACHINE_TYPE" ${FLEX_FLAG:+--flex "$FLEX_SIZE_GB"}
source "$(dirname "$0")/../_my_env.sh"

zone="$AZ3"
IP3_VAR="OUTSCALE_INSTANCE_PUBLIC_IP_3"
INSTANCE_PUBLIC_IP_3="${!IP3_VAR:?$IP3_VAR not set (instanciate step failed?)}"

echo "Connecting to $INSTANCE_PUBLIC_IP_3 to configure cluster (node 3)..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null outscale@"${INSTANCE_PUBLIC_IP_3}" << EOF
  ${FLE_CMD:-true}
  chmod 700 /home/outscale/create-or-join-redis-cluster.sh
  sudo /home/outscale/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$INSTANCE_PUBLIC_IP_3" "$zone" 3 "$master_ip"
EOF

echo "Cluster setup complete. Access your cluster at https://$cluster_dns:8443 with username $RS_admin and password $RS_password."