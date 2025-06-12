#!/usr/bin/env bash


set -euo pipefail

# Enable debug mode if DEBUG=true is set in the environment
[[ "${DEBUG:-false}" == "true" ]] && set -x

# Dry-run mode
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  echo "Running in dry-run mode. No changes will be made."
fi

REGION="eu-west-3"
VPC_NAME="thomas-manson-vpc"  # Change to the name of the VPC you want to delete

echo "Searching for VPC with Name: $VPC_NAME"
VPC_ID=$(aws ec2 describe-vpcs \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=$VPC_NAME" \
  --query 'Vpcs[0].VpcId' \
  --output text)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "Error: No VPC found with Name tag: $VPC_NAME"
  exit 1
fi

SG_ID=$(aws ec2 describe-security-groups \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=thomas-manson-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)

if [[ "$SG_ID" == "None" ]]; then
  SG_ID=""
fi

echo "Found VPC: $VPC_ID (Name: $VPC_NAME)"

# List instances in the VPC
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

echo "The following instances are associated with VPC $VPC_ID:"
for ID in $INSTANCE_IDS; do
  echo "- $ID"
done

# Will be initialized after subnet fetch
SUBNET_IDS=""

echo "[DEBUG] Fetching subnet IDs directly for VPC ID: $VPC_ID"
SUBNET_IDS=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[*].SubnetId" \
  --output text | xargs 2>/dev/null)

echo "[DEBUG] Filtered SUBNET_IDS: '$SUBNET_IDS'"

if [[ -z "$SUBNET_IDS" ]]; then
  echo "Error: No subnets found in VPC $VPC_ID"
  exit 1
fi

IGW_ID=$(aws ec2 describe-internet-gateways \
  --region "$REGION" \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text)

if [[ "$IGW_ID" == "None" ]]; then
  IGW_ID=""
fi

ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[?Associations[?Main!=`true`]].RouteTableId' \
  --output text)

if [[ -z "$ROUTE_TABLE_IDS" || "$ROUTE_TABLE_IDS" == "None" ]]; then
  ROUTE_TABLE_IDS=""
fi

echo ""
echo "The following resources will be deleted:"
echo "Security Group: $SG_ID"
echo "Instances: $INSTANCE_IDS"
echo "Subnets: $SUBNET_IDS"
echo "Internet Gateway: $IGW_ID"
echo "Route Tables: $ROUTE_TABLE_IDS"
echo "VPC: $VPC_ID"

echo ""
read -p "Type 'delete' to confirm deletion: " CONFIRM
if [[ "$CONFIRM" != "delete" ]]; then
  echo "Aborted."
  exit 0
fi

# Terminate instances
if [[ -n "$INSTANCE_IDS" ]]; then
  echo "Terminating instances..."
  if [ "$DRY_RUN" = false ]; then
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$REGION"
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$REGION"
  else
    echo "[Dry-run] Would run: aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region \"$REGION\""
    echo "[Dry-run] Would run: aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region \"$REGION\""
  fi
fi

# Delete subnets
for SUBNET_ID in $SUBNET_IDS; do
  echo "Deleting Subnet: $SUBNET_ID"
  if [ "$DRY_RUN" = false ]; then
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID" --region "$REGION"
  else
    echo "[Dry-run] Would run: aws ec2 delete-subnet --subnet-id \"$SUBNET_ID\" --region \"$REGION\""
  fi
done

# Detach and delete IGW
if [ -n "$IGW_ID" ]; then
  echo "Detaching and deleting IGW: $IGW_ID"
  if [ "$DRY_RUN" = false ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region "$REGION"
  else
    echo "[Dry-run] Would run: aws ec2 detach-internet-gateway --internet-gateway-id \"$IGW_ID\" --vpc-id \"$VPC_ID\" --region \"$REGION\""
    echo "[Dry-run] Would run: aws ec2 delete-internet-gateway --internet-gateway-id \"$IGW_ID\" --region \"$REGION\""
  fi
fi

# Delete route tables (except main)
for RTB_ID in $ROUTE_TABLE_IDS; do
  echo "Deleting Route Table: $RTB_ID"
  if [ "$DRY_RUN" = false ]; then
    aws ec2 delete-route-table --route-table-id "$RTB_ID" --region "$REGION"
  else
    echo "[Dry-run] Would run: aws ec2 delete-route-table --route-table-id \"$RTB_ID\" --region \"$REGION\""
  fi
done

if [ -n "$SG_ID" ]; then
  echo "Deleting Security Group: $SG_ID"
  if [ "$DRY_RUN" = false ]; then
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION"
  else
    echo "[Dry-run] Would run: aws ec2 delete-security-group --group-id \"$SG_ID\" --region \"$REGION\""
  fi
fi

# Finally, delete the VPC
echo "Deleting VPC: $VPC_ID"
if [ "$DRY_RUN" = false ]; then
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
else
  echo "[Dry-run] Would run: aws ec2 delete-vpc --vpc-id \"$VPC_ID\" --region \"$REGION\""
fi

echo "VPC teardown complete."