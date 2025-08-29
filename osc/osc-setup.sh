#!/usr/bin/env bash
set -euo pipefail

# --- Pré-requis ---
# - oapi-cli installé et configuré (~/.osc/config.json)   [oai_citation:0‡Outscale Documentation](https://docs.outscale.com/en/userguide/Installing-and-Configuring-oapi-cli.html)
# - jq installé
#
# Utilisation :
#   ./osc-setup.sh OWNER_NAME eu-west-2 [PROFILE]
# Ex :
#   ./osc-setup.sh thomas-manson eu-west-2 default

source "$(dirname "$0")/../_my_env.sh"

OAPI_PROFILE="-default"

NAME="${OWNER}-net"

# 1) Create Net (équiv. VPC)
NET_ID=$(
  oapi-cli --profile " CreateNet \
    --IpRange "10.0.0.0/16" | jq -r '.Net.NetId'
)
echo "Created Net: $NET_ID"

# Tags (syntaxes alternatives supportées par oapi-cli)   [oai_citation:1‡Outscale Documentation](https://docs.outscale.com/en/userguide/Installing-and-Configuring-oapi-cli.html)
oapi-cli --profile "$OAPI_PROFILE" CreateTags \
  "--ResourceIds[]" "$NET_ID" \
  --Tags.0.Key "Owner" ..Value "$OWNER" \
  --Tags.1.Key "Name"  ..Value "$NAME"

# 2) Create Internet Service (équiv. IGW) + Link to Net   [oai_citation:2‡Outscale Documentation](https://docs.outscale.com/en/userguide/Creating-an-Internet-Service.html)
IGW_ID=$(
  oapi-cli --profile "$OAPI_PROFILE" CreateInternetService \
  | jq -r '.InternetService.InternetServiceId'
)
echo "Created Internet Service: $IGW_ID"

oapi-cli --profile "$OAPI_PROFILE" LinkInternetService \
  --NetId "$NET_ID" \
  --InternetServiceId "$IGW_ID"
echo "Linked Internet Service to Net"

# 3) Route table + default route to internet service   [oai_citation:3‡Outscale Documentation](https://docs.outscale.com/en/userguide/Creating-a-Route-Table.html)
RTB_ID=$(
  oapi-cli --profile "$OAPI_PROFILE" CreateRouteTable \
    --NetId "$NET_ID" | jq -r '.RouteTable.RouteTableId'
)
echo "Created Route Table: $RTB_ID"

# La route Internet utilise GatewayId = InternetServiceId   [oai_citation:4‡Outscale Documentation](https://docs.outscale.com/en/userguide/Creating-a-Route-Table.html)
oapi-cli --profile "$OAPI_PROFILE" CreateRoute \
  --RouteTableId "$RTB_ID" \
  --DestinationIpRange "0.0.0.0/0" \
  --GatewayId "$IGW_ID"
echo "Created 0.0.0.0/0 route to Internet Service"

# 4) 3 subnets publics (a, b, c) + association route table + IP publique auto   [oai_citation:5‡Outscale Documentation](https://docs.outscale.com/en/userguide/Creating-a-Subnet-in-a-Net.html)
declare -a SUBNET_IDS=()
declare -a AZS=()
for i in 1 2 3; do
  CIDR="10.0.$((i * 10)).0/24"
  # Sous-régions : ${REGION}a / b / c (ex: eu-west-2a)
  SUFFIX=$(echo a b c | cut -d' ' -f$i)
  SUBREGION="${REGION}${SUFFIX}"

  SUBNET_ID=$(
    oapi-cli --profile "$OAPI_PROFILE" CreateSubnet \
      --NetId "$NET_ID" \
      --IpRange "$CIDR" \
      --SubregionName "$SUBREGION" \
    | jq -r '.Subnet.SubnetId'
  )
  echo "Created Subnet: $SUBNET_ID in ${SUBREGION}"
  SUBNET_IDS+=("$SUBNET_ID")
  AZS+=("$SUBREGION")

  # Associer la route table au subnet
  oapi-cli --profile "$OAPI_PROFILE" LinkRouteTable \
    --RouteTableId "$RTB_ID" \
    --SubnetId "$SUBNET_ID"

  # Activer l’attribution d’IP publique automatique (équiv. map-public-ip-on-launch)   [oai_citation:6‡Outscale Documentation](https://docs.outscale.com/en/userguide/Modifying-a-Subnet-Attribute.html)
  oapi-cli --profile "$OAPI_PROFILE" UpdateSubnet \
    --SubnetId "$SUBNET_ID" \
    --MapPublicIpOnLaunch true
done

# 5) Security Group + règles (Inbound/Outbound)
# Création du SG   [oai_citation:7‡Outscale Documentation](https://docs.outscale.com/en/userguide/Creating-a-Security-Group.html)
SG_ID=$(
  oapi-cli --profile "$OAPI_PROFILE" CreateSecurityGroup \
    --NetId "$NET_ID" \
    --SecurityGroupName "${OWNER}-sg" \
    --Description "Security group for ${OWNER}" \
  | jq -r '.SecurityGroup.SecurityGroupId'
)
echo "Created Security Group: $SG_ID"

# Inbound SSH from anywhere + ports externes (ex. Redis Enterprise UI/APIs)
# Créer une règle = CreateSecurityGroupRule --Flow Inbound ...   [oai_citation:8‡Outscale Documentation](https://docs.outscale.com/en/userguide/Adding-Rules-to-a-Security-Group.html)
oapi-cli --profile "$OAPI_PROFILE" CreateSecurityGroupRule \
  --Flow Inbound \
  --SecurityGroupId "$SG_ID" \
  --IpProtocol tcp --FromPortRange 22 --ToPortRange 22 \
  --IpRange "0.0.0.0/0"

for port in 8001 8070 8080 3346 8443 9443; do
  oapi-cli --profile "$OAPI_PROFILE" CreateSecurityGroupRule \
    --Flow Inbound \
    --SecurityGroupId "$SG_ID" \
    --IpProtocol tcp --FromPortRange "$port" --ToPortRange "$port" \
    --IpRange "0.0.0.0/0"
done

# Inbound internes (CIDR Net)
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
  oapi-cli --profile "$OAPI_PROFILE" CreateSecurityGroupRule \
    --Flow Inbound \
    --SecurityGroupId "$SG_ID" \
    --IpProtocol "$proto" --FromPortRange "$from" --ToPortRange "$to" \
    --IpRange "10.0.0.0/8"
done

# UDP 53/5353 externe et interne
for cidr in "0.0.0.0/0" "10.0.0.0/8"; do
  for port in 53 5353; do
    oapi-cli --profile "$OAPI_PROFILE" CreateSecurityGroupRule \
      --Flow Inbound \
      --SecurityGroupId "$SG_ID" \
      --IpProtocol udp --FromPortRange "$port" --ToPortRange "$port" \
      --IpRange "$cidr"
  done
done

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
  echo "NET_ID=$NET_ID"
  echo "IGW_ID=$IGW_ID"
  echo "RTB_ID=$RTB_ID"
  echo "SG_ID=$SG_ID"
  echo "SUBNET1=${SUBNET_IDS[0]}"
  echo "SUBNET2=${SUBNET_IDS[1]}"
  echo "SUBNET3=${SUBNET_IDS[2]}"
  echo "AZ1=${AZS[0]}"
  echo "AZ2=${AZS[1]}"
  echo "AZ3=${AZS[2]}"
} >> "$ENV_FILE"
echo "Environment variables saved to $ENV_FILE"