#!/usr/bin/env bash
set -euo pipefail

echo "###################################################################################"
echo "# Uptime before installing Redis Enterprise"
echo "###################################################################################"

who -b
awk '{print $1}' /proc/uptime
uptime -p

echo "###################################################################################"
echo "# Installing Redis Enterprise on Ubuntu 22.04"
echo "###################################################################################"

# --- Install Redis Enterprise ---
cd /home/ubuntu/redis-enterprise
bash -x ./install.sh -c ./redis-install-answers.txt