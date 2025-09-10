#!/usr/bin/env bash
set -euo pipefail

# Prérequis:
# - oapi-cli installé et profil configuré (~/.osc/config.json)
# - jq installé
# Docs install oapi-cli : https://docs.outscale.com/en/userguide/Installing-and-Configuring-oapi-cli.html

# Usage: ./osc-setup.sh 
# Ex:    ./osc-setup.sh 

source "$(dirname "$0")/../_my_env.sh"

OAPI_PROFILE="default"
#REGION is not needed as the access key is bound to a specific region
# It's used for subnet creation in specific AZs
REGION="${OUTSCALE_REGION:-eu-west-2}"
NAME="${OWNER}-net"

pause() {
  read -rp "Press any key to continue..." -n1
  echo    # retour à la ligne après la touche
}


echo "Using profile=$OAPI_PROFILE region=$REGION owner=$OWNER"

# 1) Create Net (équivalent VPC)
NET_ID="$(
  oapi-cli --profile "$OAPI_PROFILE"  \
    CreateNet --IpRange "10.0.0.0/16" \
  | jq -r '.Net.NetId'
)"
echo "Created Net: $NET_ID"
pause

# Tagger le Net (CreateTags)
oapi-cli --profile "$OAPI_PROFILE"  \
  CreateTags \
  --ResourceIds '["'"$NET_ID"'"]' \
  --Tags '[{"Key":"Owner","Value":"'"$OWNER"'"},{"Key":"Name","Value":"'"$NAME"'"}]'

pause


# 2) Create Internet Service + Link to Net
IGW_ID="$(
  oapi-cli --profile "$OAPI_PROFILE"  \
    CreateInternetService \
  | jq -r '.InternetService.InternetServiceId'
)"
echo "Created Internet Service: $IGW_ID"
pause


oapi-cli --profile "$OAPI_PROFILE"  \
  LinkInternetService \
  --NetId "$NET_ID" \
  --InternetServiceId "$IGW_ID"
echo "Linked Internet Service to Net"
pause


# 3) Route table + default route to Internet Service
RTB_ID="$(
  oapi-cli --profile "$OAPI_PROFILE"  \
    CreateRouteTable --NetId "$NET_ID" \
  | jq -r '.RouteTable.RouteTableId'
)"
echo "Created Route Table: $RTB_ID"
pause


# CreateRoute 0.0.0.0/0 -> InternetService
oapi-cli --profile "$OAPI_PROFILE"  \
  CreateRoute \
  --RouteTableId "$RTB_ID" \
  --DestinationIpRange "0.0.0.0/0" \
  --GatewayId "$IGW_ID"
echo "Created default route to Internet Service"
pause


# 4) 3 Subnets publics (a, b, c) + association RT + IP publique auto
declare -a SUBNET_IDS=()
declare -a AZS=()
for i in 1 2 3; do
  CIDR="10.0.$((i * 10)).0/24"
  SUFFIX=$(echo a b c | cut -d' ' -f$i)
  SUBREGION="${REGION}${SUFFIX}"

  SUBNET_ID="$(
    oapi-cli --profile "$OAPI_PROFILE"  \
      CreateSubnet \
      --NetId "$NET_ID" \
      --IpRange "$CIDR" \
      --SubregionName "$SUBREGION" \
    | jq -r '.Subnet.SubnetId'
  )"
  echo "Created Subnet: $SUBNET_ID in ${SUBREGION}"
  SUBNET_IDS+=("$SUBNET_ID")
  AZS+=("$SUBREGION")

  # Associer la route table
  oapi-cli --profile "$OAPI_PROFILE"  \
    LinkRouteTable \
    --RouteTableId "$RTB_ID" \
    --SubnetId "$SUBNET_ID"

  # Activer MapPublicIpOnLaunch
  oapi-cli --profile "$OAPI_PROFILE"  \
    UpdateSubnet \
    --SubnetId "$SUBNET_ID" \
    --MapPublicIpOnLaunch true
done
pause


# 5) Security Group + règles
SG_ID="$(
  oapi-cli --profile "$OAPI_PROFILE"  \
    CreateSecurityGroup \
    --NetId "$NET_ID" \
    --SecurityGroupName "${OWNER}-sg" \
    --Description "Security group for ${OWNER}" \
  | jq -r '.SecurityGroup.SecurityGroupId'
)"
echo "Created Security Group: $SG_ID"
pause


# Inbound SSH depuis Internet
oapi-cli --profile "$OAPI_PROFILE"  \
  CreateSecurityGroupRule \
  --Flow Inbound \
  --SecurityGroupId "$SG_ID" \
  --IpProtocol tcp --FromPortRange 22 --ToPortRange 22 \
  --IpRange "0.0.0.0/0"
pause


# Ports externes (UI / APIs Redis Enterprise)
for port in 8001 8070 8080 3346 8443 9443; do
  oapi-cli --profile "$OAPI_PROFILE"  \
    CreateSecurityGroupRule \
    --Flow Inbound \
    --SecurityGroupId "$SG_ID" \
    --IpProtocol tcp --FromPortRange "$port" --ToPortRange "$port" \
    --IpRange "0.0.0.0/0"
done
pause
# Plage de port externes
for range in "10000-10049" "10051-19999"; do
  from=$(echo $range | cut -d- -f1)
  to=$(echo $range | cut -d- -f2)

  oapi-cli --profile "$OAPI_PROFILE" \
    CreateSecurityGroupRule \
    --Flow Inbound \
    --SecurityGroupId "$SG_ID" \
    --IpProtocol tcp \
    --FromPortRange "$from" \
    --ToPortRange "$to" \
    --IpRange "0.0.0.0/0"
done


# Ports internes (CIDR du Net)
for spec in \
  "tcp 8001 8001" "tcp 8002 8002" "tcp 8004 8004" "tcp 8006 8006" \
  "tcp 8071 8071" "tcp 8443 8443" "tcp 9080 9080" "tcp 9081 9081" \
  "tcp 9082 9082" "tcp 9091 9091" "tcp 9125 9125" "tcp 9443 9443" \
  "tcp 10050 10050" "tcp 1968 1968" "tcp 3346 3346" "tcp 3355 3355" \
  "tcp 36379 36379" \
  "tcp 10000 10049" "tcp 10051 19999" "tcp 20000 29999" \
  "tcp 3333 3345"  "tcp 3347 3349"  "tcp 3350 3354"
do
  read -r proto from to <<<"$spec"
  oapi-cli --profile "$OAPI_PROFILE"  \
    CreateSecurityGroupRule \
    --Flow Inbound \
    --SecurityGroupId "$SG_ID" \
    --IpProtocol "$proto" --FromPortRange "$from" --ToPortRange "$to" \
    --IpRange "10.0.0.0/8"
done
pause


# UDP 53/5353 externe et interne
for cidr in "0.0.0.0/0" "10.0.0.0/8"; do
  for port in 53 5353; do
    oapi-cli --profile "$OAPI_PROFILE"  \
      CreateSecurityGroupRule \
      --Flow Inbound \
      --SecurityGroupId "$SG_ID" \
      --IpProtocol udp --FromPortRange "$port" --ToPortRange "$port" \
      --IpRange "$cidr"
  done
done
pause


echo ""
echo "===== OUTSCALE Resource Summary ====="
echo "NET (VPC):   $NET_ID"
echo "IGW (IS):    $IGW_ID"
echo "ROUTE TABLE: $RTB_ID"
echo "SEC GROUP:   $SG_ID"
echo "SUBNETS:     ${SUBNET_IDS[*]}"
echo "AZs:         ${AZS[*]}"
echo "====================================="

# Sauvegarde d’un env file pour réutilisation
ENV_FILE="../_my_env.sh"
{
  echo "# Generated environment variables (OUTSCALE)"
  echo "OSC_NET_ID=$NET_ID"
  echo "OSC_IGW_ID=$IGW_ID"
  echo "OSC_RTB_ID=$RTB_ID"
  echo "OSC_SG_ID=$SG_ID"
  echo "OSC_SUBNET1=${SUBNET_IDS[0]}"
  echo "OSC_SUBNET2=${SUBNET_IDS[1]}"
  echo "OSC_SUBNET3=${SUBNET_IDS[2]}"
  echo "OSC_AZ1=${AZS[0]}"
  echo "OSC_AZ2=${AZS[1]}"
  echo "OSC_AZ3=${AZS[2]}"
} >> "$ENV_FILE"
echo "Environment variables saved to $ENV_FILE"