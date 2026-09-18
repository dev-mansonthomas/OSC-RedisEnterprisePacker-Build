# Spec — Cluster create-or-join (⚠️ not executed by this repo)

**File present here:** `image_scripts/create-or-join-redis-cluster.sh` (94 lines)
**Actually executed by:** `OSC-RedisEnterprisePacker-Run` → `osc/cluster_instanciate.sh`
**Verified against code:** HEAD `fe7c72f`. `diff` against
`../OSC-RedisEnterprisePacker-Run/image_scripts/create-or-join-redis-cluster.sh` → **byte-identical**.
**Tests:** none exist.

> **Status: dead code in this repository.** The Packer template
> (`packer/redis_ubuntu_outscale_image.pkr.hcl`) uploads only
> `prepare-and-install-redis-install.sh` and `redis-install-answers.txt`. This script is
> never provisioned into the OMI and never runs during a build. It is documented here because
> it sits in the tree, and because the duplicate will drift from the `-Run` copy.
> **Recommended: delete it here** and keep `-Run` as the single owner (TODO T-14).

## Purpose (in the Run phase)

Bootstrap the first Redis Enterprise node (`init`) or attach an additional node (`join`) to an
existing cluster, with rack awareness derived from the Outscale subregion.

## Invocation

```sh
create-or-join-redis-cluster.sh <cluster_dns> <RS_admin> <RS_password> \
                                <init|join> <node_external_addr> <zone> <node_id> [master_ip]
```

| # | Parameter | Required | Purpose |
|---|---|---|---|
| 1 | `cluster_dns` | yes | cluster name passed to `rladmin cluster create name` |
| 2 | `RS_admin` | yes | Redis Enterprise admin email/login |
| 3 | `RS_password` | yes | admin password |
| 4 | `mode` | yes | `init` (create) or `join` |
| 5 | `node_external_addr` | yes | public IP → `external_addr` |
| 6 | `zone` | yes | Outscale subregion → `rack_id` |
| 7 | `node_id` | yes | index, used only for the `/etc/hosts` alias |
| 8 | `master_ip` | only when `mode=join` | node to join |

Validation: parameters 1-7 are checked non-empty in a loop; `master_ip` is checked only for
`join`; an unrecognised `mode` prints a usage line and exits 1. Exit code on any missing
parameter is 1. ✅

## Behaviour

1. Derive the private IP: `ip -4 -o addr show | awk '!/ lo /' | cut -d/ -f1 | grep '^10\.'`
2. Append `<ip> ip-<dashed-ip> redis-node-<node_id>` to `/etc/hosts`
   (`hostnamectl set-hostname` is commented out)
3. Tee all output to `/var/log/redis-enterprise-init.log`
4. `init` → `rladmin cluster create name … username … password … external_addr …
   flash_enabled rack_aware rack_id <zone>`
5. `join` → `rladmin cluster join username … password … nodes <master_ip> external_addr …
   flash_enabled rack_id <zone>`, retried **10 times, 30 s apart**, so secondaries can start
   before the master is ready

## Edge cases and defects

| Case | Current behaviour | Assessment |
|---|---|---|
| Password handling | Passed as `argv[3]`, so it is visible in `ps aux`/`/proc/<pid>/cmdline` to **any local user** for the whole run, and passed again on the `rladmin` command line | 🔴 T-15 |
| Password logging | The validation loop does `echo "$var_name=${!var_name}"` for all seven parameters, including `RS_password`, and everything is tee'd to `/var/log/redis-enterprise-init.log` ⇒ **the admin password is written to a world-readable-by-default log in cleartext** | 🔴 T-15 |
| Non-10/8 private subnet | `grep '^10\.'` returns nothing, `internal_ip` is empty, `/etc/hosts` gets a malformed line. Currently masked because `osc-setup.sh` hardcodes `10.0.0.0/16`. | 🟠 T-16 |
| Multiple 10.x addresses on the VM | `internal_ip` becomes multi-line ⇒ `hostname_fmt` and the `/etc/hosts` line are corrupt | 🟠 T-16 |
| `set -euo pipefail` placement | Set on line 16, **after** the positional parameters are read (lines 5-13). With fewer than 8 arguments, `master_ip=$8` on line 13 would abort under `set -u` — but `set -u` is not active yet, so it silently becomes empty and the explicit checks handle it. Fragile but currently correct. | 🟡 |
| `flash_enabled` requested | **Correct.** Run attaches two `io1` volumes and runs `prepare_flash.sh -y` (after a udev `rotational=0` fix) *before* this script runs, so the flash device exists by then. `34c7939`'s complaint was fixed by `699110c`. | ✅ |
| Re-run on an already-clustered node | `rladmin cluster create` fails; the script exits 1 with a named error. `/etc/hosts` has already been appended to again. | 🟡 not idempotent |
| `join` exhausts 10 retries | Named error, exit 1 after ~5 minutes | ✅ bounded |

## Acceptance criteria

1. `mode=init` on a fresh node creates a cluster named `<cluster_dns>` with `rack_aware`
   enabled and `rack_id` = the passed zone.
2. `mode=join` attaches the node to `<master_ip>` with the same `rack_id` semantics, retrying
   up to 10 times.
3. Any missing required parameter (including `master_ip` in `join` mode) exits 1 with a message
   naming the parameter, before any `rladmin` call.
4. An unrecognised `mode` prints usage and exits 1.
5. All output is captured in `/var/log/redis-enterprise-init.log`.
6. **(Not currently met)** The admin password never appears in `ps` output, in
   `/var/log/redis-enterprise-init.log`, or in any other log — pass it via stdin, an
   `0600` file, or an environment variable, and exclude it from the echo loop.
7. **(Not currently met)** Private-IP detection works for any RFC1918 range and for a VM with
   several addresses.
8. **Met.** `flash_enabled` is only reached after Run has attached the `io1` volumes and run
   `prepare_flash.sh -y`.
9. **(Not currently met)** This file exists in exactly one repository.
