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

# --- Wait for cloud-init before touching apt ---
# cloud-init rewrites /etc/apt/sources.list to a regional mirror. Running apt while it
# is mid-rewrite yields a partial index: the build of 2026-09-18 10:07 fetched only
# jammy-updates / jammy-security / jammy-backports and NOT the jammy release pocket, so
# every universe-only package became invisible and `dpkg-sig` failed with "Unable to
# locate package". The successful 00:25 build had used the regional mirror; this one had
# fallen back to archive.ubuntu.com. Waiting removes the race.
if command -v cloud-init >/dev/null; then
  echo "Waiting for cloud-init to finish..."
  cloud-init status --wait || echo "WARNING: cloud-init reported a problem (continuing)" >&2
  cloud-init status --long || true
fi
echo "--- APT sources in effect ---"
grep -rhE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || true

# --- Guarantee the release pocket and the universe component ---
# dpkg-sig, iotop and netcat live in jammy/universe, which is NOT covered by
# jammy-updates or jammy-security: a missing release pocket makes them unavailable while
# everything else still installs, so the failure looks unrelated to apt.
# shellcheck source=/dev/null  # guest file, only present in the build VM
. /etc/os-release
UBUNTU_CODENAME="${UBUNTU_CODENAME:-jammy}"
if ! grep -rqE "^deb .*[[:space:]]${UBUNTU_CODENAME}[[:space:]].*universe" \
       /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  echo "Release pocket with universe missing for ${UBUNTU_CODENAME}; adding it."
  echo "deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME} main restricted universe multiverse" \
    > /etc/apt/sources.list.d/99-release-pocket.list
fi

# --- Update base system ---
# Retried: a mirror can be briefly unavailable, and failing the whole build on a
# transient 5xx wastes a ~5 minute run.
apt_update_ok=0
for attempt in 1 2 3; do
  if apt-get update -y; then apt_update_ok=1; break; fi
  echo "apt-get update failed (attempt $attempt/3); retrying in 10s..." >&2
  sleep 10
done
if [ "$apt_update_ok" -ne 1 ]; then
  echo "ERROR: apt-get update failed three times" >&2
  exit 1
fi

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

# --- Hard requirements ---
# The .deb signature check needs gpg and ar, both in the base system. Asserted rather
# than installed, and the build must not continue without them: skipping signature
# verification is not an acceptable degradation.
for req in gpg ar; do
  command -v "$req" >/dev/null || {
    echo "ERROR: '$req' is required to verify the Redis package signature" >&2
    exit 1
  }
done
echo "Signature verification tooling present: gpg, ar."

# --- Operator conveniences: best effort, never fatal ---
# None of these is needed by Redis Enterprise. The build of 2026-09-18 10:26 aborted
# because 'iotop' was judged unavailable, which is the wrong trade: a ~5 minute build
# and a publishable image should not be lost over a diagnostic tool. Installed one at a
# time so one bad package cannot take the rest down with it, and the failures are
# reported together at the end.
#
# dpkg-sig is in this list now: it is only an optional cross-check of the gpg
# verification, and it is the universe-only package that broke the 10:07 build.
UTILS="vim iotop iputils-ping curl jq netcat-openbsd dnsutils dpkg-sig"
missing_utils=""
for pkg in $UTILS; do
  if apt-get install -y "$pkg" >/dev/null 2>&1; then
    echo "  installed $pkg"
  else
    echo "  WARNING: could not install $pkg" >&2
    missing_utils="$missing_utils $pkg"
  fi
done

if [ -n "$missing_utils" ]; then
  echo "WARNING: these convenience packages are absent from the image:$missing_utils" >&2
  echo "         The build continues: none of them is required by Redis Enterprise." >&2
  # Printed for diagnosis, because a missing universe package usually means the APT
  # sources are wrong -- which is what the 10:07 failure actually was.
  for pkg in $missing_utils; do
    echo "--- apt-cache policy $pkg ---" >&2
    apt-cache policy "$pkg" >&2 2>&1 || true
  done
fi

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

# --- Verify the Redis .deb signature ---
# Exactly one package, so a change in the tarball layout cannot silently pass the glob.
deb_count=$(find /home/$USER/redis-enterprise -maxdepth 1 -name 'redislabs_*.deb' | wc -l)
if [ "$deb_count" -ne 1 ]; then
  echo "ERROR: expected exactly one redislabs_*.deb, found $deb_count" >&2
  exit 1
fi
REDIS_DEB="$(find /home/$USER/redis-enterprise -maxdepth 1 -name 'redislabs_*.deb' | head -1)"

# Signature verification, with dpkg-sig as the reference implementation.
#
# History, because this took three attempts and the reasoning matters:
#
#  1. dpkg-sig lives in jammy/universe only, and the 10:07 build died at "Unable to
#     locate package dpkg-sig". That looked like a good reason to drop it.
#  2. So the check was rewritten to use gpg directly, assuming `_gpgorigin` was a
#     debsigs-style DETACHED signature over the concatenation of the archive members.
#     The 10:33 build answered that with "gpg: not a detached signature".
#  3. It is not. dpkg-sig's own format puts a CLEARSIGNED MANIFEST in `_gpgorigin`,
#     listing the md5, sha1 and size of each member. Verifying it means checking the
#     signature over that manifest AND that the members still match the checksums.
#
# The apt causes behind (1) are fixed, and dpkg-sig now installs reliably, so it is
# used as the authority: it is the reference implementation of the format, and
# reimplementing a checksum-manifest parser for the security-critical step is a worse
# risk than depending on it. verify_deb_manifest() below is the fallback for when it is
# absent, and it handles both formats.
#
# What makes this trustworthy either way is the fingerprint pinned above: whichever tool
# checks the signature, it can only be satisfied by the key this repository expects.

# verify_deb_manifest <deb> -- fallback verifier, used only when dpkg-sig is absent.
verify_deb_manifest() {
  local deb="$1" tmp sig rc member
  tmp="$(mktemp -d)"; sig="$tmp/_gpgorigin"

  if ! ar p "$deb" _gpgorigin > "$sig" 2>/dev/null || [ ! -s "$sig" ]; then
    echo "ERROR: $deb carries no _gpgorigin member -- it is NOT signed" >&2
    rm -rf "$tmp"; return 1
  fi

  if head -1 "$sig" | grep -q 'BEGIN PGP SIGNED MESSAGE'; then
    # dpkg-sig format: a clearsigned manifest. The signature covers the manifest, so
    # authenticating it is step one; step two is checking the members still match.
    echo "    _gpgorigin is a clearsigned manifest (dpkg-sig format)"
    if ! gpg --verify "$sig" 2>&1 | sed 's/^/    /'; then :; fi
    if ! gpg --verify "$sig" >/dev/null 2>&1; then
      echo "ERROR: the manifest signature is not valid" >&2
      rm -rf "$tmp"; return 1
    fi

    # Manifest lines are "<md5> <sha1> <size> <member>", one per file, after a
    # "Files:" header. Selected by SHAPE -- 32 hex, 40 hex, digits, name -- rather than
    # by skipping known header keywords: a header such as
    # "Date: Fri, 18 Sep 2026 12:39:14 +0200" also splits into four-plus fields, and an
    # earlier version of this loop tried to checksum "Sep 2026 12:39:14 +0200".
    local checked=0
    while read -r md5 sha1 size member; do
      printf '%s' "$md5"  | grep -qE '^[0-9a-f]{32}$' || continue
      printf '%s' "$sha1" | grep -qE '^[0-9a-f]{40}$' || continue
      printf '%s' "$size" | grep -qE '^[0-9]+$'       || continue
      [ -n "$member" ] || continue
      ar p "$deb" "$member" > "$tmp/member" 2>/dev/null || {
        echo "ERROR: manifest lists '$member', absent from the archive" >&2
        rm -rf "$tmp"; return 1
      }
      local a_md5 a_sha1 a_size
      a_md5="$(md5sum  "$tmp/member" | cut -d' ' -f1)"
      a_sha1="$(sha1sum "$tmp/member" | cut -d' ' -f1)"
      a_size="$(wc -c < "$tmp/member" | tr -d ' ')"
      if [ "$a_md5" != "$md5" ] || [ "$a_sha1" != "$sha1" ] || [ "$a_size" != "$size" ]; then
        echo "ERROR: '$member' does not match the signed manifest" >&2
        echo "       expected md5=$md5 sha1=$sha1 size=$size" >&2
        echo "       actual   md5=$a_md5 sha1=$a_sha1 size=$a_size" >&2
        rm -rf "$tmp"; return 1
      fi
      echo "    manifest match: $member"
      checked=$((checked + 1))
    done < <(gpg --decrypt "$sig" 2>/dev/null | tr -s ' \t' '  ')

    if [ "$checked" -eq 0 ]; then
      echo "ERROR: the signed manifest listed no files to check" >&2
      rm -rf "$tmp"; return 1
    fi
    echo "    $checked member(s) verified against the signed manifest"
    rm -rf "$tmp"; return 0
  fi

  # debsigs format: a detached signature over the concatenated members.
  echo "    _gpgorigin is a detached signature (debsigs format)"
  local members=()
  while IFS= read -r member; do
    [ "$member" = "_gpgorigin" ] || members+=("$member")
  done < <(ar t "$deb")
  if [ "${#members[@]}" -eq 0 ]; then
    echo "ERROR: $deb has no archive members" >&2; rm -rf "$tmp"; return 1
  fi
  ar p "$deb" "${members[@]}" > "$tmp/payload" || { rm -rf "$tmp"; return 1; }
  gpg --verify "$sig" "$tmp/payload" 2>&1 | sed 's/^/    /'
  gpg --verify "$sig" "$tmp/payload" >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

echo "--- Verifying the signature of $(basename "$REDIS_DEB") ---"
if command -v dpkg-sig >/dev/null; then
  dpkg-sig --verify "$REDIS_DEB" || {
    echo "ERROR: signature verification of $REDIS_DEB failed (dpkg-sig)" >&2
    echo "       The package is not signed by the pinned Redis key." >&2
    exit 1
  }
  echo "Signature verified by dpkg-sig against the pinned Redis key."
else
  echo "dpkg-sig absent; falling back to direct verification." >&2
  if ! verify_deb_manifest "$REDIS_DEB"; then
    echo "ERROR: signature verification of $REDIS_DEB failed" >&2
    echo "       The package is not signed by the pinned Redis key." >&2
    exit 1
  fi
  echo "Signature verified against the pinned Redis key."
fi


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
# Host firewall (TODO T-19)
###################################################################################
# Applied AFTER install.sh, so the rule set is enabled on a node whose services are
# already in place and can be checked; and so a firewall mistake cannot be confused
# with an installation failure.
#
# The image is unconfigured by design, so the build-time pass gives PORT-scope defence
# only: SSH and the Redis Enterprise port set are reachable, everything else is denied.
# CIDR-scope defence is the deployment's job -- OSC-RedisEnterprisePacker-Run, or the
# customer, re-runs the same script with real CIDRs:
#
#   redis-enterprise-firewall --cluster-cidr 10.0.0.0/16 \
#                             --client-cidr 10.20.0.0/16 \
#                             --operator-cidr 203.0.113.4/32
#
# firewall=no is kept in the answer file on purpose: we own the rule set here, and
# letting install.sh add its own on top would mean two sources of truth for the same
# policy. The previous mismatch between a commented-out UFW block and firewall=no is the
# likeliest reason enabling UFW never worked -- see docs/reference/hardening-baseline.md.
echo "--- Installing the firewall helper ---"
install -m 0755 /home/$USER/redis-enterprise-firewall.sh \
  /usr/local/sbin/redis-enterprise-firewall
echo "Installed /usr/local/sbin/redis-enterprise-firewall"

if command -v ufw >/dev/null; then
  echo "--- Applying the build-time firewall (port scope only) ---"
  /usr/local/sbin/redis-enterprise-firewall

  # Assert the result rather than trusting it: an inactive firewall after this point
  # would be a silent loss of the whole control.
  if ! ufw status | head -1 | grep -q 'Status: active'; then
    echo "ERROR: ufw is not active after applying the rules" >&2
    exit 1
  fi
  echo "Host firewall active."

  # SSH must survive, or the image is unusable and Packer's next step would hang.
  ufw status | grep -qE '(^|[[:space:]])22/tcp' || {
    echo "ERROR: no rule allows SSH; refusing to publish an unreachable image" >&2
    exit 1
  }
  echo "SSH rule present."
else
  echo "ERROR: ufw is not installed; cannot apply the host firewall" >&2
  exit 1
fi


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
# This script itself, uploaded by Packer. Confirmed still present on a VM launched from
# ami-57a302f4: it describes how the image was built and has no business in it.
rm -f  /home/$USER/prepare-and-install-redis-install.sh
rm -f  /home/$USER/redis-enterprise-firewall.sh
rm -f  /home/$USER/redis-install-answers.txt
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