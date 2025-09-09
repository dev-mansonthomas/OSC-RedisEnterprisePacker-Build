#!/usr/bin/env bash
set -euo pipefail

if [ -d /home/ubuntu ]; then
  USER=ubuntu
elif [ -d /home/outscale ]; then
  USER=outscale
else
  echo "Erreur: aucun utilisateur reconnu (ni /home/ubuntu ni /home/outscale trouvés)" >&2
  exit 1
fi

echo "Detected user: $USER"

# --- Update base system ---
apt-get update -y
apt-get upgrade -y

# --- Configure umask for root & ubuntu ---
echo "umask 0022" | tee -a /root/.profile > /dev/null
echo "umask 0022" >> ~/.profile
umask 0022

# --- Configure & enable UFW (firewall) ---
# redis-install-answers.txt : firewall=yes if ufw 

# apt-get install -y ufw
# ufw default deny incoming
# ufw default allow outgoing

# ufw allow in on lo
# ufw allow out on lo

# ufw allow ssh
# ufw allow 8001/tcp
# ufw allow 8070/tcp
# ufw allow 8443/tcp
# ufw allow 8444/tcp
# ufw allow 9080/tcp
# ufw allow 9081/tcp
# ufw allow 9443/tcp
# ufw allow 10000:19999/tcp
# ufw allow 20000:29999/tcp
# ufw allow 53/udp
# ufw allow 5353/udp
# ufw --force enable

# systemctl daemon-reload

# --- Installation of Audit Daemon---
# consider this later
#apt-get install -y auditd
# 

#--- install dpkg-sig to check redis .deb signature ---
apt-get install -y dpkg-sig

# --- Install utilities ---
apt-get -y install vim iotop iputils-ping curl jq netcat dnsutils

# --- Disable swap permanently ---
swapoff -a
systemctl mask swap.target

# --- Package clean up ---
apt-get remove --purge -y snapd apport unattended-upgrades
apt-get autoremove -y


# --- Remove systemd-resolved to avoid conflifct with Redis mdns server ---
sed -i '$a DNSStubListener=no' /etc/systemd/resolved.conf
mv /etc/resolv.conf /etc/resolv.conf.orig
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
service systemd-resolved restart


# --- Harden SSH configuration ---
# somehow, this wasn't working on Outscale

#sed -i '/^#\?PermitRootLogin/s/.*/PermitRootLogin no/' /etc/ssh/sshd_config
#sed -i '/^#\?PasswordAuthentication/s/.*/PasswordAuthentication no/' /etc/ssh/sshd_config
#sed -i '/^#\?ChallengeResponseAuthentication/s/.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
#grep -q '^AllowUsers' /etc/ssh/sshd_config && \
#  sed -i "/^AllowUsers/s/.*/AllowUsers $USER/" /etc/ssh/sshd_config || \
#  echo "AllowUsers $USER" | tee -a /etc/ssh/sshd_config
#systemctl restart sshd


# --- Disabling AppArmor ---
systemctl disable --now apparmor

# --- Extract Redis Enterprise archive ---
cd /home/$USER
mkdir redis-enterprise
tar -xf redis-enterprise.tar -C redis-enterprise
mv redis-install-answers.txt ./redis-enterprise

# --- Import Redis GPG key ---
gpg --import /home/$USER/redis-enterprise/rlec_install_utils_tmpdir/GPG-KEY-redislabs-packages || {
  echo "ERROR: Failed to import Redis GPG key"
  exit 1
}

# --- Verify Redis .deb signature ---
dpkg-sig --verify /home/$USER/redis-enterprise/redislabs_*.deb || {
  echo "ERROR: Signature verification of Redis .deb package failed"
  exit 1
}


# --- deamon reload ---
systemctl daemon-reload

# Expand ephemeral port range to avoid collisions
echo 'net.ipv4.ip_local_port_range = 30000 65535' | tee -a /etc/sysctl.conf
sysctl -p /etc/sysctl.conf


echo "###################################################################################"
echo "# Installing Redis Enterprise on Ubuntu 22.04"
echo "###################################################################################"

# --- Install Redis Enterprise ---
cd /home/$USER/redis-enterprise
bash ./install.sh -c ./redis-install-answers.txt

#After installing the Redis Enterprise Software package on the instance and before running through the setup process, you must give the group redislabs permission to the EBS volume by running the following command from the OS command-line interface (CLI):
#chown redislabs:redislabs /< ebs folder name>