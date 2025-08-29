#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../_my_env.sh"

NAME="${OWNER}-vpc"

# Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region "$REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Owner,Value=$OWNER},{Key=Name,Value=$NAME}]" \
  --query 'Vpc.VpcId' \
  --output text)

echo "Created VPC: $VPC_ID"

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Owner,Value=$OWNER}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)

echo "Created IGW: $IGW_ID"

# Attach IGW to VPC
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --output text

echo "Attached IGW to VPC"

# Create public route table
RTB_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Owner,Value=$OWNER},{Key=Name,Value=PublicRouteTable}]" \
  --query 'RouteTable.RouteTableId' \
  --output text)

echo "Created Route Table: $RTB_ID"

# Create default route to IGW
aws ec2 create-route \
  --route-table-id "$RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" \
  --region "$REGION" \
  --output text

echo "Created default route to IGW"

# Create 3 public subnets in AZs a, b, c
SUBNET_IDS=()
AZS=()
for i in 1 2 3; do
  CIDR="10.0.$((i * 10)).0/24"
  AZ="eu-west-3$(echo a b c | cut -d' ' -f$i)"

  SUBNET_ID=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block "$CIDR" \
    --availability-zone "$AZ" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Owner,Value=$OWNER},{Key=Name,Value=PublicSubnet-${AZ: -1}}]" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text)

  echo "Created Subnet: $SUBNET_ID in AZ: $AZ"
  SUBNET_IDS+=("$SUBNET_ID")
  AZS+=("$AZ")

  # Enable auto-assign public IP
  aws ec2 modify-subnet-attribute \
    --subnet-id "$SUBNET_ID" \
    --map-public-ip-on-launch \
    --region "$REGION" \
    --output text

  # Associate route table
  aws ec2 associate-route-table \
    --subnet-id "$SUBNET_ID" \
    --route-table-id "$RTB_ID" \
    --region "$REGION" \
    --output text

  echo "Configured subnet $SUBNET_ID as public"
done

echo "VPC setup complete. VPC ID: $VPC_ID"

# Create Security Group
SG_ID=$(aws ec2 create-security-group \
  --group-name "${OWNER}-sg" \
  --description "Security group for ${OWNER}" \
  --vpc-id "$VPC_ID" \
  --region "$REGION" \
  --query 'GroupId' \
  --output text)

echo "Created Security Group: $SG_ID"

#
# Add ingress rules
echo "Authorizing SSH access..."
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region "$REGION" \
  --output text

echo "Authorizing external access ports..."
for port in 8001 8070 8080 3346 8443 9443 10000-10049 10051-19999; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$port" \
    --cidr 0.0.0.0/0 \
    --region "$REGION" \
    --output text
    
done

echo "Authorizing internal access ports..."
for port in 8001 8002 8004 8006 8071 8443 9080 9081 9082 9091 9125 9443 10050 10000-10049 10051-19999 1968 3333-3345 3346 3347-3349 3350-3354 3355 36379 20000-29999; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port "$port" \
    --cidr 10.0.0.0/8 \
    --region "$REGION" \
    --output text
done

echo "Authorizing UDP ports (53, 5353) internal and external..."
for port in 53 5353; do
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol udp \
    --port "$port" \
    --cidr 0.0.0.0/0 \
    --region "$REGION" \
    --output text

  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol udp \
    --port "$port" \
    --cidr 10.0.0.0/8 \
    --region "$REGION" \
    --output text
done



echo ""
echo "===== AWS Resource Summary ====="
echo "VPC ID: $VPC_ID"
echo "Internet Gateway ID: $IGW_ID"
echo "Route Table ID: $RTB_ID"
echo "Security Group ID: $SG_ID"
echo "Subnets:"
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query "Subnets[*].{ID:SubnetId,AZ:AvailabilityZone}" \
  --output table
echo "================================"

# Save environment variables for reuse
ENV_FILE="../_my_env.sh"
{
  echo "# Generated environment variables"
  echo "VPC_ID=$VPC_ID"
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