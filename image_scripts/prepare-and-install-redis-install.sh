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

# --- Wait upgrade to complete, otherwise there might be some issues installing dpkg-sig ---
sleep 5

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
mkdir -p redis-enterprise
tar -xf redis-enterprise.tar -C redis-enterprise
mv redis-install-answers.txt ./redis-enterprise

# --- Import Redis GPG key, then check it is the key we expect ---
#
# The key ships INSIDE the tarball, and is then used to verify a .deb from that same
# tarball. On its own that is circular: an attacker who replaces the tarball supplies
# both the package and the key that vouches for it. Pinning the fingerprint here breaks
# the circle, because the expected value comes from the repository, not the archive.
#
# Fingerprint of "Redis Labs Package Signing Key (2020) <support@redislabs.com>",
# observed in the builds of 2025-11-25 (8.0.2-41) and 2026-09-18 (8.2.0-78).
# When Redis rotates the key this WILL fail, and that is the point: verify the new
# fingerprint against Redis's own published value before changing it here.
REDIS_GPG_FINGERPRINT="${REDIS_GPG_FINGERPRINT:-5E8EFA2409E5C44FB529BE20EC5EC593D7D1529F}"

GPG_KEY_FILE="/home/$USER/redis-enterprise/rlec_install_utils_tmpdir/GPG-KEY-redislabs-packages"

if [ ! -f "$GPG_KEY_FILE" ]; then
  echo "ERROR: Redis GPG key not found in the tarball: $GPG_KEY_FILE" >&2
  exit 1
fi

# Check the fingerprint BEFORE importing, so a hostile key never enters the keyring.
if ! key_fprs="$(gpg --with-colons --import-options show-only --import "$GPG_KEY_FILE" 2>/dev/null \
                 | awk -F: '$1 == "fpr" { print $10 }')"; then
  echo "ERROR: could not read the fingerprint of $GPG_KEY_FILE" >&2
  exit 1
fi

if ! printf '%s\n' "$key_fprs" | grep -qx "$REDIS_GPG_FINGERPRINT"; then
  echo "ERROR: unexpected Redis signing key." >&2
  echo "       expected: $REDIS_GPG_FINGERPRINT" >&2
  echo "       found:    $(printf '%s' "$key_fprs" | tr '\n' ' ')" >&2
  echo "       Either the tarball is not authentic, or Redis rotated its signing key." >&2
  echo "       Verify against Redis's published fingerprint before updating" >&2
  echo "       REDIS_GPG_FINGERPRINT in image_scripts/prepare-and-install-redis-install.sh." >&2
  exit 1
fi

echo "Redis GPG key fingerprint matches the pinned value: $REDIS_GPG_FINGERPRINT"

gpg --import "$GPG_KEY_FILE" || {
  echo "ERROR: Failed to import Redis GPG key" >&2
  exit 1
}

# --- Verify Redis .deb signature ---
# dpkg-sig exits 0 on success, but be explicit about which package was verified: the
# glob would silently pass if the tarball layout ever changed.
deb_count=$(find /home/$USER/redis-enterprise -maxdepth 1 -name 'redislabs_*.deb' | wc -l)
if [ "$deb_count" -ne 1 ]; then
  echo "ERROR: expected exactly one redislabs_*.deb, found $deb_count" >&2
  exit 1
fi

dpkg-sig --verify /home/$USER/redis-enterprise/redislabs_*.deb || {
  echo "ERROR: Signature verification of Redis .deb package failed" >&2
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


###################################################################################
# Post-install assertions
###################################################################################
# install.sh is told ntp=no, and it warns that clock synchronisation is now our
# problem: "NOT auto-configuring NTP, please manually synchronize cluster node
# clocks." Redis Enterprise coordinates nodes against wall-clock time, so skew breaks
# a cluster. rlcheck does NOT test this (its tests are verify_capabilities,
# verify_existing_sockets, verify_host_settings, verify_owner_and_group,
# verify_port_range). It works today only because Ubuntu ships systemd-timesyncd
# enabled -- nothing asserted it. Now it does. (TODO T-12)
echo "--- Verifying time synchronisation ---"
if ! command -v timedatectl >/dev/null; then
  echo "ERROR: timedatectl absent; cannot verify clock synchronisation" >&2
  exit 1
fi

timedatectl show || true
ntp_enabled="$(timedatectl show -p NTP --value 2>/dev/null || echo unknown)"
if [ "$ntp_enabled" != "yes" ]; then
  echo "ERROR: network time synchronisation is not enabled (NTP=$ntp_enabled)." >&2
  echo "       Redis Enterprise requires synchronised clocks across cluster nodes." >&2
  echo "       Either enable systemd-timesyncd, or set ntp=yes in" >&2
  echo "       image_scripts/redis-install-answers.txt so the installer configures it." >&2
  exit 1
fi
echo "Time synchronisation enabled (NTP=yes)."

# NTPSynchronized can legitimately still be false moments after boot, so it is
# reported but not fatal: what matters for the image is that the mechanism is ON.
echo "NTPSynchronized=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"


###################################################################################
# Image cleanup -- MUST be the last thing this script does
###################################################################################
# Everything below runs after Redis Enterprise is installed and verified. Two separate
# concerns, both of which only make sense at the very end.

# --- 1. Reclaim the installer payload (TODO T-31) ---
# The tarball is 343 MB-1 GB and its extracted tree roughly doubles that, on a 30 GB
# root. Neither is needed once the .deb is installed. The gnupg home holds the signing
# key material imported above and has no business in a published image.
echo "--- Reclaiming installer payload ---"
du -sh /home/$USER/redis-enterprise.tar /home/$USER/redis-enterprise 2>/dev/null || true
rm -f  /home/$USER/redis-enterprise.tar
rm -rf /home/$USER/redis-enterprise
rm -rf /home/$USER/.gnupg /root/.gnupg
rm -f  /etc/resolv.conf.orig
apt-get clean
rm -rf /var/lib/apt/lists/*
echo "Root filesystem usage after cleanup:"
df -h / || true

# --- 2. De-identify the image (TODO T-11) ---
# Without this every VM launched from the OMI shares the same SSH host keys and the
# same machine-id. Shared host keys let one node impersonate another and make host-key
# pinning worthless -- which is why the Run repo currently disables host-key checking
# altogether. This is the precondition for fixing that.
#
# Host keys are regenerated on first boot by the ssh-keygen systemd units that ship
# with Ubuntu's openssh-server, and cloud-init regenerates machine-id, so removing
# them here is safe and is the documented way to prepare an image.
echo "--- De-identifying the image ---"

rm -f /etc/ssh/ssh_host_*
echo "SSH host keys removed; regenerated on first boot."

# systemd requires machine-id to EXIST but treats an empty file as "uninitialised",
# which makes it regenerate one per VM. Deleting the file outright can break boot.
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
echo "machine-id cleared."

# cloud-init caches instance metadata, including the SSH keys it injected and the
# instance id. Left in place, a VM from this image can believe it has already run.
# --seed is not available on every cloud-init release, so degrade rather than fail.
if command -v cloud-init >/dev/null; then
  if   cloud-init clean --logs --seed 2>/dev/null; then :
  elif cloud-init clean --logs        2>/dev/null; then
    echo "note: cloud-init has no --seed; removing the seed directory directly"
    rm -rf /var/lib/cloud/seed
  else
    echo "WARNING: cloud-init clean failed; clearing /var/lib/cloud by hand" >&2
    rm -rf /var/lib/cloud/*
  fi
else
  rm -rf /var/lib/cloud/*
fi
echo "cloud-init state cleared."

# Shell history and the operator's authorized_keys: the build keypair is injected by
# Outscale at launch, so anything baked in here is a leftover, not a requirement.
rm -f /home/$USER/.bash_history /root/.bash_history
rm -f /home/$USER/.ssh/authorized_keys /root/.ssh/authorized_keys

# Login records name the build session, not the customer's. Truncated rather than
# deleted: the files must keep existing with their ownership for logins to be recorded.
truncate -s 0 /var/log/wtmp /var/log/btmp /var/log/lastlog 2>/dev/null || true

# A named list, not a blanket find over /var/log: Redis Enterprise's own install
# artefacts are worth keeping in the image for support, and a wildcard sweep would be
# one upstream path change away from destroying them.
for f in /var/log/syslog /var/log/auth.log /var/log/kern.log \
         /var/log/dpkg.log /var/log/apt/history.log /var/log/apt/term.log \
         /var/log/cloud-init.log /var/log/cloud-init-output.log; do
  [ -f "$f" ] && truncate -s 0 "$f"
done

echo "###################################################################################"
echo "# Image ready: Redis Enterprise installed, unconfigured, de-identified"
echo "###################################################################################"