# Spec — Image preparation and Redis Enterprise install

**Implementation:** `image_scripts/prepare-and-install-redis-install.sh` (130 lines) +
`image_scripts/redis-install-answers.txt` (9 lines)
**Runs:** inside the Packer build VM, as root, via `sudo -E`
**Verified against code:** HEAD `fe7c72f`, and against the real build log
`build_scripts/packer.out` (2025-11-25).
**Tests:** none of our own. Redis's `rlcheck` runs as the last stage of `install.sh`.

## Purpose

Prepare a stock Ubuntu 22.04 LTS VM for Redis Enterprise Software, verify the package's
signature, and install it unattended — leaving the node installed but **unconfigured** (no
cluster, no credentials, no databases).

## Inputs

| Path | Provided by | Purpose |
|---|---|---|
| `/home/outscale/redis-enterprise.tar` | Packer file provisioner | the 993 MB Redis Enterprise Jammy tarball |
| `/home/outscale/redis-install-answers.txt` | Packer file provisioner | unattended answers for `install.sh` |
| `DEBIAN_FRONTEND=noninteractive` | Packer `environment_vars` | suppresses debconf's dialog frontend |

No arguments. No configurable variables — behaviour is fixed at build time.

### `redis-install-answers.txt`

| Key | Value | Effect |
|---|---|---|
| `ignore_swap` | `no` | installer aborts if swap is on → the `swapoff` step above is a hard prerequisite |
| `systune` | `yes` | runs `/opt/redislabs/sbin/systune.sh` and re-runs it on supervisor start |
| `ntp` | `no` | installer does **not** configure NTP; it prints *"please manually synchronize cluster node clocks"* |
| `firewall` | `no` | installer does not configure a host firewall |
| `rlcheck` | `yes` | runs Redis's post-install validation suite |
| `ignore_existing_osuser_osgroup` | `no` | abort if `redislabs` user/group already exists |
| `add_to_path`, `update_env_path` | `yes` | add `/opt/redislabs/bin` to `PATH` |
| `skip_updating_env_path` | `no` | (consistent with the two above) |

## Steps

| # | Action | Notes |
|---|---|---|
| 1 | Detect `ubuntu` vs `outscale` home dir → `USER` | exits 1 if neither. Shadows the shell's own `USER` var. |
| 2 | `apt-get update && apt-get upgrade -y`, then `sleep 5` | the sleep was added in `a7b309a` because a following `apt-get install` raced the upgrade's dpkg lock |
| 3 | `umask 0022` appended to `/root/.profile` and `~/.profile` | `sudo -E` preserves `HOME=/home/outscale` (confirmed: gpg later created `/home/outscale/.gnupg`), so both files get it |
| 4 | Install `dpkg-sig` | needed for signature verification |
| 5 | Install `vim iotop iputils-ping curl jq netcat dnsutils` | operator convenience |
| 6 | `swapoff -a` + `systemctl mask swap.target` | Redis Enterprise requires no swap; satisfies `ignore_swap=no` |
| 7 | `apt-get remove --purge -y snapd apport unattended-upgrades` + `autoremove` | trims the image and stops snapd churn — **also disables automatic security updates** |
| 8 | Append `DNSStubListener=no` to `/etc/systemd/resolved.conf`; move `/etc/resolv.conf` aside; symlink it to `/run/systemd/resolve/resolv.conf`; restart `systemd-resolved` | frees UDP 53 for Redis Enterprise's own DNS/mDNS responder |
| 9 | `systemctl disable --now apparmor` | see `docs/adr/0006` |
| 10 | Extract the tarball to `/home/$USER/redis-enterprise`; move the answer file in | |
| 11 | `gpg --import …/rlec_install_utils_tmpdir/GPG-KEY-redislabs-packages` | key `EC5EC593D7D1529F`, *"Redis Labs Package Signing Key (2020)"* — shipped **inside the tarball** |
| 12 | `dpkg-sig --verify redislabs_*.deb` | exits 1 with a named error on failure |
| 13 | `systemctl daemon-reload` | |
| 14 | Append `net.ipv4.ip_local_port_range = 30000 65535` to `/etc/sysctl.conf` + `sysctl -p` | keeps ephemeral ports clear of Redis's `10000-29999` and `3333-3355` ranges |
| 15 | `bash ./install.sh -c ./redis-install-answers.txt` | ends with `systune`, then `rlcheck` |

Steps 8, 9, 11 and the `firewall=no`/`ntp=no` answers are the security-relevant trade-offs;
each has an ADR (`0005`–`0008`) and a TODO entry.

### Deliberately disabled, left in the file as comments

- **UFW** (lines 30-49): install, default-deny inbound, allow the Redis Enterprise port list,
  `ufw --force enable`. Paired with `firewall=yes` in the answer file. README TODO: *"test
  renable ufw + firewall=yes in the answer file"*.
- **`auditd`** (lines 55): *"consider this later"*.
- **SSH hardening** (lines 83-89): `PermitRootLogin no`, `PasswordAuthentication no`,
  `ChallengeResponseAuthentication no`, `AllowUsers $USER`. Comment says *"somehow, this
  wasn't working on Outscale"* — **root cause**: Ubuntu cloud images ship
  `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`, whose `Include` is processed first and
  whose directives therefore win over edits to the main `sshd_config`. The fix is a drop-in
  file in `sshd_config.d/` with a higher-priority (lower-numbered) name, not `sed` on the
  main file.

## Outputs

An Ubuntu 22.04 root filesystem with:

- Redis Enterprise Software installed under `/opt/redislabs`, `redislabs` user/group created,
  services installed but **no cluster** (`rladmin cluster create` is the Run phase's job)
- swap masked, `systune` applied, ephemeral port range widened
- AppArmor disabled, no host firewall, no `auditd`, no automatic updates
- **Left behind:** `/home/outscale/redis-enterprise.tar` (993 MB) and the extracted
  `/home/outscale/redis-enterprise/` tree, `/home/outscale/.gnupg`, `/etc/resolv.conf.orig`,
  and the apt cache — roughly 2 GB of the 30 GB root, all baked into the OMI

## Edge cases

| Case | Current behaviour | Assessment |
|---|---|---|
| Neither `/home/ubuntu` nor `/home/outscale` | Named error, exit 1 | ✅ |
| GPG import fails | Named error, exit 1 | ✅ |
| `.deb` signature invalid | Named error, exit 1 | ✅ (but see next row) |
| Tarball itself tampered with | **Not detected.** The verification key comes from inside the same tarball, so an attacker who replaces the tarball supplies a matching key and `.deb`. No checksum on the tarball either. | 🔴 T-13 |
| Several `redislabs_*.deb` in the tarball | `dpkg-sig --verify` receives a glob; a single non-signed match fails the build | ✅ fail-closed |
| Script re-run on the same host | Not idempotent — `umask`, `DNSStubListener` and `sysctl` lines are appended again, and `mv /etc/resolv.conf` fails. Irrelevant under Packer (fresh VM each build). | 🟡 |
| Node clock drifts | Nothing in this repo asserts time sync. `systemd-timesyncd` happens to be installed and restarted (seen in `packer.out`), which is why clusters work in practice. | 🟠 T-12 |
| VM launched from the OMI | Shares `/etc/ssh/ssh_host_*` and `/etc/machine-id` with every other VM from that OMI — no `cloud-init clean` | 🔴 T-11 |

## Acceptance criteria

1. Exit code `0`; `packer.out` contains `Installation complete.`
2. `rlcheck` reports `ALL TESTS PASSED`. *(Verified 2025-11-25.)*
3. `/opt/redislabs/bin/rladmin` exists and the `redislabs` user/group were created.
4. `swapon --show` is empty; `systemctl is-enabled swap.target` → `masked`.
5. `sysctl net.ipv4.ip_local_port_range` → `30000 65535`.
6. No cluster exists on the image (`rladmin status` reports an un-bootstrapped node).
7. GPG verification of the `.deb` succeeded before `install.sh` ran.
8. **(Not currently met)** The tarball's SHA-256 matches a value pinned in the repo, and the
   signing key's fingerprint is pinned out-of-band rather than read from the tarball.
9. **(Not currently met)** `ufw status` → active with only the Redis Enterprise port list open.
10. **(Not currently met)** `aa-status` → enforcing; `auditd` installed and enabled.
11. **(Not currently met)** `sshd -T` shows `permitrootlogin no` and
    `passwordauthentication no`.
12. **(Not currently met)** `timedatectl` shows an active NTP sync source, asserted by the build.
13. **(Not currently met)** The tarball and extracted tree are deleted, `apt-get clean` is run,
    and `cloud-init clean --logs` + removal of `/etc/ssh/ssh_host_*` and `/etc/machine-id`
    happen as the last provisioning step.
