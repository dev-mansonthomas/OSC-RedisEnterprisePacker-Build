#!/usr/bin/env bash
source "$(dirname "$0")/../_my_env.sh"

cluster_dns="$CLUSTER_DNS"
RS_admin="$REDIS_LOGIN"
RS_password="$REDIS_PWD"
mode="init"
zone="$AZ1"

./instanciate_image_aws.sh 1
source "$(dirname "$0")/../_my_env.sh"
# Configure Redis cluster on the remote instance
echo "Connecting to $INSTANCE_PUBLIC_IP_1 to configure cluster..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${INSTANCE_PUBLIC_IP_1}" << EOF
  chmod 700 /home/ubuntu/create-or-join-redis-cluster.sh
  sudo /home/ubuntu/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$INSTANCE_PUBLIC_IP_1" "$zone" 1
EOF

echo "sleep 30 seconds to let the cluster initialize..."
sleep 30  

mode="join"
master_ip="$INSTANCE_PUBLIC_IP_1"

./instanciate_image_aws.sh 2
source "$(dirname "$0")/../_my_env.sh"
zone="$AZ2"

# Configure Redis cluster on the remote instance
echo "Connecting to $INSTANCE_PUBLIC_IP_2 to configure cluster..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${INSTANCE_PUBLIC_IP_2}" << EOF
  chmod 700 /home/ubuntu/create-or-join-redis-cluster.sh
  sudo /home/ubuntu/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "${INSTANCE_PUBLIC_IP_2}" "$zone" 2 "$master_ip"
EOF
read -p "Press [Enter] to continue..."

./instanciate_image_aws.sh 3
source "$(dirname "$0")/../_my_env.sh"
zone="$AZ3"

# Configure Redis cluster on the remote instance
echo "Connecting to $INSTANCE_PUBLIC_IP_3 to configure cluster..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${INSTANCE_PUBLIC_IP_3}" << EOF
  chmod 700 /home/ubuntu/create-or-join-redis-cluster.sh
  sudo /home/ubuntu/create-or-join-redis-cluster.sh "$cluster_dns" "$RS_admin" "$RS_password" "$mode" "$INSTANCE_PUBLIC_IP_3" "$zone"  3 "$master_ip"
EOF

echo "Cluster setup complete. Access your cluster at https://$cluster_dns:8443 with username $RS_admin and password $RS_password."
