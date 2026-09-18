# ADR 0006 — Disable AppArmor in the image

- **Status:** Accepted provisionally — **should be revisited**
- **Date:** **`df62416` (2025-09-09)** — corrected 2026-09-17; an earlier version of this ADR
  wrongly said "since the first commit". Git bisect of the file shows the line absent through
  `4311d68` (2025-08-28) and present from `df62416` ("working, documentation still to be done"),
  the same day as `eb402cd` "Outscale working, Flex to be done".
- **Evidence:** `image_scripts/prepare-and-install-redis-install.sh` line 93:
  `systemctl disable --now apparmor`; confirmed executing in `build_scripts/packer.out`
  (*"Removed /etc/systemd/system/sysinit.target.wants/apparmor.service"*)

## Context

Redis Enterprise Software installs a supervised process tree under `/opt/redislabs` (proxies,
shards, `cnm_http`, envoy, its own DNS responder) which binds low ports, writes across several
filesystem locations and manipulates network namespaces. Ubuntu's default AppArmor profiles
are not written with that in mind, and confinement denials surface as obscure runtime failures
rather than clear errors.

## Decision

`systemctl disable --now apparmor` during the build.

## Consequences

**Positive**

- Removes a whole class of hard-to-diagnose denials during install and at runtime.
- The `redislabs` process tree runs unconfined, which is what Redis's own installer assumes.

**Negative**

- **Removes Mandatory Access Control from the image.** A compromised Redis process has only
  DAC between it and the rest of the system.
- Combined with ADR 0005 (no host firewall) and no `auditd`, the image has materially less
  hardening than stock Ubuntu 22.04 — the opposite of what a SecNumCloud delivery should show.
- No *explicit* evidence was recorded that AppArmor broke anything — but the **timing is
  suggestive**: the line appeared exactly during the Outscale bring-up, on the day Outscale first
  worked. That correlation makes it more likely a real fix than a precaution, and it should be
  treated as a hypothesis to test rather than dead code to delete. Contrast T-19 (UFW), where git
  proves the feature was **never** active in any revision.

**Recommended next step (TODO T-20):** build one image with AppArmor left in `complain` mode,
run `rlcheck` plus a 3-node cluster from `-Run`, and read `/var/log/audit` or
`dmesg | grep apparmor` for actual denials. If there are none, or only a few, ship an
`/etc/apparmor.d/local` profile for `/opt/redislabs` instead of disabling MAC wholesale.
