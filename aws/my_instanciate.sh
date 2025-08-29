#!/usr/bin/env bash
source "$(dirname "$0")/../_my_env.sh"

if [[ -z "${AMI_ID:-}" ]]; then
  echo "Error: AMI_ID is not set in _my_env.sh. Please build the AMI first."
  exit 1
fi


FLEX_FLAG="flex" #set to "" if you don't want flex
FLEX_SIZE_GB="200" #size of each flex volume in GB, note that it will be mounted as RAID0 so total size will be 2x this value
MACHINE_TYPE="t3.xlarge"


FLE_CMD=""
if [[ "$FLEX_FLAG" == "flex" ]]; then
  FLE_CMD="sudo /opt/redislabs/sbin/prepare_flash.sh"
fi

cluster_dns="$CLUSTER_DNS"
RS_admin="$REDIS_LOGIN"
RS_password="$REDIS_PWD"
mode="init"
zone="$AZ1"

./instanciate_image_aws.sh --subnet 1 --machine-type "$MACHINE_TYPE" ${FLEX_FLAG:+--flex "$FLEX_SIZE_GB"}
source "$(dirname "$0")/../_my_env.sh"
# Configure Redis cluster on the remote instance
echo "Connecting to $INSTANCE_PUBLIC_IP_1 to configure cluster..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${INSTANCE_PUBLIC_IP_1}" << EOF
  ${FLE_CMD:-true}
  chmod 700 /home/ubuntu/create-or-join-redis-cluster.sh
  sudo /home/ubuntu/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$INSTANCE_PUBLIC_IP_1" "$zone" 1
EOF

echo "sleep 30 seconds to let the cluster initialize..."
sleep 30  

mode="join"
master_ip="$INSTANCE_PUBLIC_IP_1"

./instanciate_image_aws.sh --subnet 2 --machine-type "$MACHINE_TYPE" ${FLEX_FLAG:+--flex "$FLEX_SIZE_GB"}
source "$(dirname "$0")/../_my_env.sh"
zone="$AZ2"

# Configure Redis cluster on the remote instance
echo "Connecting to $INSTANCE_PUBLIC_IP_2 to configure cluster..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${INSTANCE_PUBLIC_IP_2}" << EOF
  ${FLE_CMD:-true}
  chmod 700 /home/ubuntu/create-or-join-redis-cluster.sh
  sudo /home/ubuntu/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "${INSTANCE_PUBLIC_IP_2}" "$zone" 2 "$master_ip"
EOF

./instanciate_image_aws.sh --subnet 3 --machine-type "$MACHINE_TYPE" ${FLEX_FLAG:+--flex "$FLEX_SIZE_GB"}
source "$(dirname "$0")/../_my_env.sh"
zone="$AZ3"

# Configure Redis cluster on the remote instance
echo "Connecting to $INSTANCE_PUBLIC_IP_3 to configure cluster..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${INSTANCE_PUBLIC_IP_3}" << EOF
  ${FLE_CMD:-true}
  chmod 700 /home/ubuntu/create-or-join-redis-cluster.sh
  sudo /home/ubuntu/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$INSTANCE_PUBLIC_IP_3" "$zone"  3 "$master_ip"
EOF

echo "Cluster setup complete. Access your cluster at https://$cluster_dns:8443 with username $RS_admin and password $RS_password."
