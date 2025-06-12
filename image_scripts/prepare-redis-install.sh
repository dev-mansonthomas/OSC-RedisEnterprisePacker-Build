#!/usr/bin/env bash
set -euo pipefail

# --- Update base system ---
sudo apt-get update -y
sudo apt-get upgrade -y

# --- Configure & enable UFW (firewall) ---
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 8001/tcp
sudo ufw allow 8070/tcp
sudo ufw allow 8443/tcp
sudo ufw allow 8444/tcp
sudo ufw allow 9080/tcp
sudo ufw allow 9081/tcp
sudo ufw allow 9443/tcp
sudo ufw allow 10000:19999/tcp
sudo ufw allow 20000:29999/tcp
sudo ufw allow 53/udp
sudo ufw allow 5353/udp
sudo ufw --force enable

# --- Installation of Audit Daemon---
# consider this later
#sudo apt-get install -y auditd
# 

# --- Disable swap permanently ---
sudo swapoff -a
sudo systemctl mask swap.target

# --- Extract Redis Enterprise archive ---
cd /home/ubuntu
mkdir redis-enterprise
tar -xf redis-enterprise.tar -C redis-enterprise

# --- Package clean up ---
sudo apt-get remove --purge -y snapd apport unattended-upgrades
sudo apt-get autoremove -y

# --- Disable unnecessary services ---
sudo systemctl disable apt-daily.service apt-daily-upgrade.service
sudo systemctl disable pollinate.service motd-news.service

# --- Harden SSH configuration ---
sudo sed -i '/^#\?PermitRootLogin/s/.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i '/^#\?PasswordAuthentication/s/.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i '/^#\?ChallengeResponseAuthentication/s/.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sudo grep -q '^AllowUsers' /etc/ssh/sshd_config && \
  sudo sed -i '/^AllowUsers/s/.*/AllowUsers ubuntu/' /etc/ssh/sshd_config || \
  echo 'AllowUsers ubuntu' | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart sshd
