#!/usr/bin/env bash
source "$(dirname "$0")/../_my_env.sh"
set -euo pipefail

# ---------- Params ----------
NODES=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes) NODES="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--nodes <odd between 3 and 35>]

Default value : --nodes 3
AZ deployment : round-robin on 3 AZ/subnets (AZ1, AZ2, AZ3)
EOF
      exit 0
      ;;
    *) echo "Arg inconnu: $1"; exit 1 ;;
  esac
done

# ---------- Validation ----------
if ! [[ "$NODES" =~ ^[0-9]+$ ]]; then
  echo "Error: --nodes must be an integer. Got: $NODES"; exit 1
fi
if (( NODES < 3 || NODES > 35 || NODES % 2 == 0 )); then
  echo "Error: --nodes must be odd and 3 ≤ N ≤ 35. Got: $NODES"; exit 1
fi
if [[ -z "${AMI_ID:-}" && -z "${OUTSCALE_AMI_ID:-}" ]]; then
  echo "Error: AMI_ID/OUTSCALE_AMI_ID not set in _my_env.sh"; exit 1
fi

# ---------- Constantes / env ----------
SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
TARGET_SSH_KEY="${OUTSCALE_SSH_KEY}"

cluster_dns="${OUTSCALE_CLUSTER_DNS}"
RS_admin="${REDIS_LOGIN}"
RS_password="${REDIS_PWD}"

# Flex (udev + prepare_flash) – exécuté côté VM
FLE_CMD=""
if [[ "${FLEX_FLAG:-}" == "flex" ]]; then
  FLE_CMD=$(cat <<'EOF'
set -euo pipefail
sudo tee /etc/udev/rules.d/99-rotational-fix.rules >/dev/null <<'RULES'
ACTION=="add|change", KERNEL=="sd*", ATTR{queue/rotational}="0"
ACTION=="add|change", KERNEL=="vd*", ATTR{queue/rotational}="0"
RULES
sudo udevadm control --reload
for d in /sys/block/sd* /sys/block/vd*; do
  [ -e "$d" ] && sudo udevadm trigger --action=change --sysname-match="$(basename "$d")"
done
sudo /opt/redislabs/sbin/prepare_flash.sh -y
EOF
)
fi

# ---------- Helpers ----------
# rr_idx: 1->1, 2->2, 3->3, 4->1, 5->2, 6->3, ...
rr_idx() { local i="$1"; echo $(( ((i-1) % 3) + 1 )); }

# lance un nœud et retourne son IP (à partir de OUTSCALE_INSTANCE_PUBLIC_IP_<index>)
launch_node() {
  local node_idx="$1"
  local subnet_idx; subnet_idx="$(rr_idx "$node_idx")"

  ./instanciate_image_outscale.sh \
    --node-num "${node_idx}" \
    --subnet "${subnet_idx}" 
  #relead env file as new var is set for the IP of the new instance
  source "$(dirname "$0")/../_my_env.sh"
}

# configure un nœud (init ou join)
configure_node() {
  local ip="$1" zone="$2" mode="$3" ord="$4" master_ip="${5:-}"

  scp $SSH_OPTS -i "$TARGET_SSH_KEY" \
    ../image_scripts/create-or-join-redis-cluster.sh \
    outscale@"$ip":/home/outscale/create-or-join-redis-cluster.sh

  ssh $SSH_OPTS -i "$TARGET_SSH_KEY" outscale@"$ip" <<EOF
  ${FLE_CMD:-true}
  chmod 700 /home/outscale/create-or-join-redis-cluster.sh
  sudo /home/outscale/create-or-join-redis-cluster.sh \
    "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$ip" "$zone" "$ord" ${master_ip:+"$master_ip"}
EOF
}

# ---------- Déploiement ----------
declare -a NODE_IPS

# Node 1 (init) sur AZ1
zone="$OSC_AZ1"
echo ">>> Déploiement node 1 (init) sur AZ1…"
launch_node 1
ip_master="${OUTSCALE_INSTANCE_PUBLIC_IP_1:?OUTSCALE_INSTANCE_PUBLIC_IP_1 manquante}"
NODE_IPS[1]="$ip_master"
configure_node "$ip_master" "$zone" "init" 1
echo "sleep 30 seconds to let the cluster initialize..."
sleep 30

# Nodes 2..N (join), round-robin sur AZ1/AZ2/AZ3
for i in $(seq 2 "$NODES"); do
  idx="$(rr_idx "$i")"
  zone_var="OSC_AZ${idx}"
  zone="${!zone_var}"
  echo ">>> Déploiement node $i (join) sur ${zone_var}…"
  launch_node "$i"
  ip_var="OUTSCALE_INSTANCE_PUBLIC_IP_${i}"
  ip_i="${!ip_var:?$ip_var manquante}"
  NODE_IPS[$i]="$ip_i"
  configure_node "$ip_i" "$zone" "join" "$i" "$ip_master"
done

# ---------- Récap DNS ----------
echo "
Configure your DNS with the following entries:
###############################################################################################"
for n in 1 2 3; do
  [[ -n "${NODE_IPS[$n]:-}" ]] && echo "ns${n}.${OUTSCALE_CLUSTER_DNS}. 10800 IN A ${NODE_IPS[$n]}"
done
for n in "${!NODE_IPS[@]}"; do
  echo "${OUTSCALE_CLUSTER_DNS}. 10800 IN A ${NODE_IPS[$n]}"
done
echo "${OUTSCALE_CLUSTER_DNS}. 10800 IN NS ns1.${OUTSCALE_CLUSTER_DNS}."
echo "${OUTSCALE_CLUSTER_DNS}. 10800 IN NS ns2.${OUTSCALE_CLUSTER_DNS}."
echo "${OUTSCALE_CLUSTER_DNS}. 10800 IN NS ns3.${OUTSCALE_CLUSTER_DNS}."
echo "###############################################################################################"

echo "Cluster setup complete. Access your cluster at https://$cluster_dns:8443 with username $RS_admin and password $RS_password."