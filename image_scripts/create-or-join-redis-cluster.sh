#!/bin/bash
set -euxo pipefail

# Paramètres requis (passés en lignes de commande)
cluster_dns=$1
RS_admin=$2
RS_password=$3
mode=$4
node_external_addr=$5
zone=$6
master_ip=$7   # seulement pour les secondaries
node_id=$8     # idem

LOG=/var/log/redis-enterprise-init.log
exec &> >(tee -a "$LOG")

# Fonction d'attente avec timeout
join_master() {
  local tries=10
  for i in $(seq 1 $tries); do
    echo "$(date -Is) - tentative $i: joindre cluster..." 
    /opt/redislabs/bin/rladmin cluster join \
      username      "${RS_admin}"           \
      password      "${RS_password}"        \
      nodes         "${master_ip}"          \
      external_addr "${node_external_addr}" \
      flash_enabled                         \
      replace_node  "${node_id}"            \
      rack_id       "${zone}"               \
      2>&1 | tee -a "$LOG"
    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "Rejoint le cluster avec succès."
      return 0
    else
      echo "Master non prêt, nouvelle tentative dans 30s..." | tee -a "$LOG"
      sleep 30
    fi
  done
  echo "Erreur : échec après $tries tentatives." >&2
  return 1
}

# Création ou jointure du cluster
if [ "$mode" = "init" ]; then
  echo "$(date -Is) - Création du cluster..." | tee -a "$LOG"
  /opt/redislabs/bin/rladmin cluster create \
    name            "${cluster_dns}"        \
    username        "${RS_admin}"           \
    password        "${RS_password}"        \
    external_addr   "${node_external_addr}" \
    flash_enabled                           \
    rack_aware rack_id "${zone}"            \
    2>&1 | tee -a "$LOG"
  
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "Erreur : impossibilité de créer le cluster" >&2
    exit 1
  fi

  echo "Cluster créé avec succès."
elif [ "$mode" = "join" ]; then
  echo "$(date -Is) - Mode join, noyau master = ${master_ip}" | tee -a "$LOG"
  join_master || exit 1
else
  echo "Usage : $0 <CLUSTER_DNS> <RS_ADMIN> <RS_PASSWORD> <mode:init|join> <MY_EXTERNAL_IP> <ZONE> [MASTER_IP NODE_ID]" >&2
  exit 1
fi

echo "Initialisation terminée." | tee -a "$LOG"