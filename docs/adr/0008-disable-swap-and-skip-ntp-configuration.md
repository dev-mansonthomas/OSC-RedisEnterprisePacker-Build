# ADR 0008 — Disable swap permanently; let Ubuntu handle time sync instead of the installer

- **Status:** Accepted (swap); **Accepted — correct choice, one assertion missing** (time sync;
  re-assessed 2026-09-17)
- **Date:** present since the first commit (`93d43c3`)
- **Evidence:** `prepare-and-install-redis-install.sh` lines 64-66
  (`swapoff -a`, `systemctl mask swap.target`); `redis-install-answers.txt` →
  `ignore_swap=no`, `ntp=no`; `build_scripts/packer.out` shows
  *"NOT auto-configuring NTP, please manually synchronize cluster node clocks"* and
  *"systemctl restart systemd-timesyncd.service"*

## Context

Two OS-level prerequisites for a healthy Redis Enterprise cluster:

**Swap.** Redis is an in-memory store; if the kernel swaps a shard out, p99 latency collapses
from microseconds to milliseconds. Redis Enterprise's installer refuses to proceed with swap
enabled unless told to ignore it.

**Clocks.** Redis Enterprise coordinates nodes and expires keys against wall-clock time;
skew between nodes breaks the cluster. The installer can configure NTP itself
(`ntp=yes`), which installs and configures `ntpd`/`chrony`.

## Decision

- Swap: `swapoff -a` **and** `systemctl mask swap.target`, with `ignore_swap=no` in the answer
  file so the installer verifies the result rather than working around it.
- Time: `ntp=no` — do **not** let the installer manage time sync. Rely on Ubuntu 22.04's
  built-in `systemd-timesyncd`, which the image keeps (ADR 0007 removes only resolved's stub
  listener, not the systemd time stack).

## Consequences

**Positive**

- Swap is off both now and after reboot; `masked` is stronger than `swapoff`, which a later
  `swapon -a` or a cloud-init disk step could undo. `ignore_swap=no` turns this into a
  build-time assertion — a regression fails the build.
- Redis's own `systune` (`systune=yes`) applies the remaining kernel tuning, so we do not
  duplicate it.
- No second time daemon fighting `systemd-timesyncd`; no `ntpd`/`chrony` to patch.

**Negative**

- **The time-sync choice is right; only the verification is missing.** To be precise about what
  `ntp=no` means: it tells the installer *not to configure NTP itself*. It is **not** a statement
  that something else is doing it — the installer says as much and hands the responsibility back
  (*"NOT auto-configuring NTP, please manually synchronize cluster node clocks"*). On Ubuntu 22.04
  the outcome is nevertheless correct, because `systemd-timesyncd` ships enabled and `packer.out`
  shows it upgraded and restarted; letting the installer add `ntpd`/`chrony` alongside it would be
  strictly worse. The real gap is that **nothing asserts it**, and `rlcheck` does not check clocks
  — verified: it runs `verify_capabilities`, `verify_existing_sockets`, `verify_host_settings`,
  `verify_owner_and_group`, `verify_port_range`, and no time-related test. So a future base image
  or a Net without internet egress could break cluster time sync with no signal. TODO T-12: add
  `timedatectl show -p NTPSynchronized --value` as a build assertion, and document Outscale's NTP
  source.
- With swap off, a memory-overcommitting database is OOM-killed rather than degraded. That is
  the correct trade-off for Redis, but it makes right-sizing mandatory — a `-Run` concern.
