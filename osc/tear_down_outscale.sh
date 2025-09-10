#!/usr/bin/env bash
set -euo pipefail

# Prérequis:
# - oapi-cli installé et profil configuré (~/.osc/config.json)
# - jq installé

# Usage:
#   ./tear_down_outscale.sh
#
# Comportement:
# 1) Termine toutes les VMs rattachées au NET_ID (trouvées via ReadVms filtré par NetId)
# 2) Détache et supprime les ressources créées: routes, associations, subnets, SG, Internet Service, Net

source "$(dirname "$0")/../_my_env.sh"

OAPI_PROFILE="${OAPI_PROFILE:-default}"

# Variables attendues dans _my_env.sh
: "${OSC_NET_ID:?OSC_NET_ID manquant dans _my_env.sh}"
: "${OSC_RTB_ID:?OSC_RTB_ID manquant dans _my_env.sh}"
: "${OSC_SG_ID:?OSC_SG_ID manquant dans _my_env.sh}"
: "${OSC_IGW_ID:?OSC_IGW_ID manquant dans _my_env.sh}"
: "${OSC_SUBNET1:?OSC_SUBNET1 manquant dans _my_env.sh}"
: "${OSC_SUBNET2:?OSC_SUBNET2 manquant dans _my_env.sh}"
: "${OSC_SUBNET3:?OSC_SUBNET3 manquant dans _my_env.sh}"
SUBNET_IDS=("$OSC_SUBNET1" "$OSC_SUBNET2" "$OSC_SUBNET3")

echo "== OUTSCALE teardown =="
echo "Profile      : $OAPI_PROFILE"
echo "Net          : $OSC_NET_ID"
echo "Route Table  : $OSC_RTB_ID"
echo "SecGroup     : $OSC_SG_ID"
echo "Int.Service  : $OSC_IGW_ID"
echo "Subnets      : ${SUBNET_IDS[*]}"
echo "--------------------------------------"

# ---------- helpers ----------
wait_vms_terminated() {
  # attend que toutes les VMs passées en args soient 'terminated'
  local ids=("$@")
  [[ ${#ids[@]} -eq 0 ]] && return 0

  echo "Attente de l'arrêt des VMs: ${ids[*]}"
  local tries=0
  while :; do
    tries=$((tries+1))
    sleep 5
    # Lit l'état de toutes les VMs (celles déjà supprimées n'apparaissent plus)
    local resp
    resp="$(oapi-cli --profile "$OAPI_PROFILE" ReadVmsState --Filters "{\"VmIds\":$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)}" || true)"

    # S'il n'y a plus d'objets VmStates -> toutes supprimées (ou l’API ne renvoie plus ces IDs)
    local states_count
    states_count="$(echo "$resp" | jq -r '(.VmStates // []) | length')"

    if [[ "$states_count" == "0" ]]; then
      echo "Toutes les VMs sont terminées / absentes."
      break
    fi

    # Sinon on check qu'aucune ne soit encore dans un autre état que 'terminated'
    local not_done
    not_done="$(echo "$resp" | jq -r '[.VmStates[] | select(.VmState != "terminated")] | length')"

    echo "  Try #$tries: restant non-terminated = $not_done"
    [[ "$not_done" == "0" ]] && break
  done
}

json_arr() {
  # rend un tableau JSON à partir d'une liste bash
  printf '%s\n' "$@" | jq -R . | jq -s .
}

safe_unlink_route_table() {
  local rtb="$1" subnet="$2"
  echo "UnlinkRouteTable: RTB=$rtb SUBNET=$subnet"
  oapi-cli --profile "$OAPI_PROFILE" UnlinkRouteTable \
    --RouteTableId "$rtb" \
    --SubnetId "$subnet" || true
}

# ---------- 1) Terminate VMs du Net ----------
echo "[1/7] Recherche des VMs dans le Net $OSC_NET_ID"
READ_VMS="$(oapi-cli --profile "$OAPI_PROFILE" ReadVms --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}")"
VM_IDS=($(echo "$READ_VMS" | jq -r '.Vms[]?.VmId' || true))

if [[ ${#VM_IDS[@]} -gt 0 ]]; then
  echo "VMs à supprimer: ${VM_IDS[*]}"
  oapi-cli --profile "$OAPI_PROFILE" DeleteVms --VmIds "$(json_arr "${VM_IDS[@]}")"
  wait_vms_terminated "${VM_IDS[@]}"
else
  echo "Aucune VM trouvée dans ce Net."
fi

# ---------- 2) Supprimer la route 0.0.0.0/0 ----------
echo "[2/7] Suppression de la route par défaut (0.0.0.0/0)"
oapi-cli --profile "$OAPI_PROFILE" DeleteRoute \
  --RouteTableId "$OSC_RTB_ID" \
  --DestinationIpRange "0.0.0.0/0" || true

# ---------- 3) Unlink route table des subnets ----------
echo "[3/7] Désassociation de la route table des subnets"

# Récupère toutes les associations (LinkRouteTableId)
RT_READ_JSON="$(oapi-cli ReadRouteTables --Filters "{\"RouteTableIds\":[\"$OSC_RTB_ID\"]}")"
# Stopper si l’API renvoie des erreurs
echo "$RT_READ_JSON" | jq -e '(.Errors|length)//0 == 0' >/dev/null || { echo "$RT_READ_JSON"; exit 1; }

LINK_IDS=$(echo "$RT_READ_JSON" | jq -r '.RouteTables[0].LinkRouteTables[].LinkRouteTableId // empty')

for link_id in $LINK_IDS; do
  echo "UnlinkRouteTable: LinkRouteTableId=$link_id"
  RESP="$(oapi-cli UnlinkRouteTable --LinkRouteTableId "$link_id")"
  echo "$RESP"
  echo "$RESP" | jq -e '(.Errors|length)//0 == 0' >/dev/null || { echo "Unlink failed"; exit 1; }
done

# ---------- 4) Supprimer la route table ----------
echo "[4/7] Suppression de la Route Table $OSC_RTB_ID"
oapi-cli --profile "$OAPI_PROFILE" DeleteRouteTable \
  --RouteTableId "$OSC_RTB_ID" || true

# ---------- 5) Supprimer le Security Group ----------
echo "[5/7] Suppression du Security Group $OSC_SG_ID"
oapi-cli --profile "$OAPI_PROFILE" DeleteSecurityGroup \
  --SecurityGroupId "$OSC_SG_ID" || true

# ---------- 6) Unlink + Delete Internet Service ----------
echo "[6/7] Délier et supprimer l'Internet Service $OSC_IGW_ID"
oapi-cli --profile "$OAPI_PROFILE" UnlinkInternetService \
  --NetId "$OSC_NET_ID" \
  --InternetServiceId "$OSC_IGW_ID" || true

oapi-cli --profile "$OAPI_PROFILE" DeleteInternetService \
  --InternetServiceId "$OSC_IGW_ID" || true

# ---------- 7) Supprimer les Subnets puis le Net ----------
echo "[7/7] Suppression des Subnets"
for sn in "${SUBNET_IDS[@]}"; do
  [[ -n "$sn" ]] || continue
  echo "  DeleteSubnet $sn"
  oapi-cli --profile "$OAPI_PROFILE" DeleteSubnet --SubnetId "$sn" || true
done

echo "Suppression du Net $OSC_NET_ID"
oapi-cli --profile "$OAPI_PROFILE" DeleteNet --NetId "$OSC_NET_ID" || true

echo "--------------------------------------"
echo "Teardown terminé."