# TODO — OSC-RedisEnterprisePacker-Build

Compiled 2026-09-16 from: the code at HEAD `fe7c72f`, `README.md` §TODO, the in-code `//todo`
marker, commit-message admissions, the last real build log (`build_scripts/packer.out`), a
`shellcheck -S style` run, and the Redis Enterprise
[port matrix](https://redis.io/docs/latest/operate/rs/networking/port-configurations/).

> **Scope note.** This file covers the **Build** repo. For the end-to-end view and the Run-phase
> findings (which carry more weight, since Run is what the customer executes) see
> `docs/architecture/build-and-run-overview.md`, and the parked Run findings in
> `docs/handover-run-findings.md`. `docs/findings.md` is the **prioritised Build view** of this
> register — start there; this file stays the exhaustive list.

**Delivery posture (confirmed 2026-09-16): customer-facing / SecNumCloud.** The hardening items
(T-11, T-19, T-20, T-22, T-23) are therefore **release blockers, not backlog**.

**Severity:** 🔴 blocker for a customer/SecNumCloud delivery · 🟠 real bug or real risk ·
🟡 correctness/robustness · ⚪ cosmetic / hygiene

There is **no test suite, no linter config and no CI** in this repo, so there are no failing or
skipped tests to report. That absence is itself T-25. Only one branch exists (`main`, clean,
in sync with `origin/main`) — no unfinished branches.

---

## Security

| ID | Sev | Item | Where | Notes |
|---|---|---|---|---|
| T-21 | ⚫ | **Superseded — this is a Run concern, see `docs/findings.md` F-02.** The customer-facing security group is created by `Run/osc/osc-setup.sh` at deployment time, and the exposure decision is the customer's. Build's own `osc-setup.sh` is **byte-identical** to Run's and is never used by the build (the Packer plugin creates its own temporary SG). The right action here is to **delete it from Build** (finding R-01), not to parameterise it. | `osc/osc-setup.sh:132-199` | Port list is correct and required; only the source CIDR is at issue, and only in Run. |
| T-40 | ⚫ | **Superseded — see `docs/findings.md` F-03** (cleartext REST API `8080`). Same reasoning as T-21: fix in Run. | `osc/osc-setup.sh:143` | |
| T-15 | 🔴 | **Redis admin password leaks two ways**: passed as `argv[3]` (visible in `ps aux` to any local user) and echoed by the parameter-validation loop into `/var/log/redis-enterprise-init.log` in cleartext. | `image_scripts/create-or-join-redis-cluster.sh:8,28-34,49-56,72-79` | Pass via stdin or an `0600` file; exclude `RS_password` from the echo loop; `chmod 600` the log. Note the executing copy lives in `-Run` — fix there too (see T-14). |
| T-13 | 🔴 | **Circular GPG trust.** The signing key is imported from `rlec_install_utils_tmpdir/GPG-KEY-redislabs-packages` *inside the tarball*, then used to verify the `.deb` from that same tarball. A tampered tarball supplies both. No checksum on the tarball either. | `prepare-and-install-redis-install.sh:101-111` | Pin Redis's key fingerprint in the repo (last build saw `EC5EC593D7D1529F`, "Redis Labs Package Signing Key (2020)") and assert it after import; add a `sha256sum -c` against a pinned digest before extraction. |
| T-11 | 🔴 | **No image de-identification.** No `cloud-init clean`, no removal of `/etc/ssh/ssh_host_*`, no reset of `/etc/machine-id`. Confirmed absent from `packer.out`. Every VM launched from the OMI shares the same SSH host keys and machine-id. | `prepare-and-install-redis-install.sh` (missing final step) | Host-key reuse enables impersonation/MITM between nodes and defeats host-key pinning. Add as the last provisioner step. |
| T-19 | 🟠 | **No host firewall.** `firewall=no` and the whole UFW block commented out. Security rests entirely on the security group (ADR 0005). | `redis-install-answers.txt:4`; `prepare-and-install-redis-install.sh:27-51` | This is the README's own TODO: *"test renable ufw + firewall=yes in the answer file"*. The commented block is a working starting point. |
| T-20 | 🟠 | **AppArmor disabled**, with no recorded evidence that it ever broke anything (ADR 0006). | `prepare-and-install-redis-install.sh:93` | Try `complain` mode + `rlcheck` + a 3-node cluster; ship an `/etc/apparmor.d/local` profile for `/opt/redislabs` instead of disabling MAC. |
| T-22 | 🟠 | **SSH hardening is commented out** and the comment blames Outscale. Real cause: Ubuntu cloud images ship `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`, processed via `Include` before the main file, so its directives win over `sed` edits. | `prepare-and-install-redis-install.sh:80-89` | Write a drop-in `/etc/ssh/sshd_config.d/10-hardening.conf` instead. Assert with `sshd -T`. |
| T-23 | 🟠 | **No audit logging.** `auditd` install is commented out as *"consider this later"*. | `prepare-and-install-redis-install.sh:53-56` | SecNumCloud / ANSSI reviews expect host audit logging. |
| T-24 | 🟠 | **Automatic security updates removed** (`apt-get remove --purge unattended-upgrades`), so a long-lived node never patches itself. | `prepare-and-install-redis-install.sh:69` | Reasonable for a golden image (patch by re-baking), but then re-baking must be a documented, scheduled operation. Decide and write it down. |
| T-26 | 🟡 | **"Internal" SG rules use `10.0.0.0/8`** while the Net is `10.0.0.0/16` — allows a whole private-range class A as source. | `osc/osc-setup.sh:184,190` | Use the Net CIDR, or better the security group's own ID as source. |
| T-27 | 🟡 | Only the **Net** is tagged. Subnets, RTB, Internet Service and SG carry no `Owner` tag, so cost attribution and orphan hunting are incomplete. | `osc/osc-setup.sh:38-41` | Tag every created resource. |
| T-28 | ⚪ | `_my_env.sh` is git-ignored ✅ and holds **no secrets** (resource IDs only) ✅; credentials live in the shell profile and `~/.osc/config.json` ✅. Verified — no action, recorded so the next audit need not re-check. | — | `.gitignore` covers `.env*`, `*.pem`, `_my_env.sh`, `redis-software/*`. |

## Correctness / reliability

| ID | Sev | Item | Where | Notes |
|---|---|---|---|---|
| T-41 | 🟠 | **POSTPONED by decision (2026-09-17) — do not attempt until a build is green again after PRs 1-4.** The build does not run inside the Net that `osc-setup.sh` creates, although it is meant to: `packer.out` shows `"SubnetId":""`, so the VM launches in Outscale's non-Net public space and the provisioned Net/subnets/SG are ignored. The `outscale-bsu` builder supports `subnet_id`, `net_id`, `subregion_name` and `associate_public_ip_address` — the HCL simply never sets them. | `packer/…pkr.hcl`; `osc/osc-setup.sh` | Rationale for postponing: the current arrangement **works**, and this is the one change that could break the build for an unrelated reason. Revisit with a known-green baseline. Meanwhile: **changes to `osc-setup.sh`'s security group cannot affect the build** — don't expect them to. See PR 5 in `docs/plan/build-remediation.md`. |
| T-01 | 🔴 | **Append-only state orphans billable cloud resources.** A second `osc-setup.sh` run creates a whole new Net and appends a second `OSC_*` block; `source` keeps the last, so the earlier Net/subnets/SG can never be torn down and keep billing. **`_my_env.sh` already contains two blocks today.** Same for `OUTSCALE_AMI_ID`. | `osc/osc-setup.sh:213-227`; `build_and_deploy_redis_image_with_packer.sh:60` | Highest-value fix. Rewrite the generated block in place (sentinel-delimited) and refuse to run when a live `OSC_NET_ID` is present unless `--force`. See ADR 0004. |
| T-02 | 🔴 | **Infinite loop in teardown.** `wait_vms_terminated` has a `tries` counter but `while :;` has no ceiling — a VM stuck in `stopping` hangs the script forever. | `osc/tear_down_outscale.sh:46-68` | Cap at ~60 attempts (5 min) and exit non-zero. |
| T-03 | 🟠 | **Two `oapi-cli` calls omit `--profile`** while every other call passes it, so with `OAPI_PROFILE` overridden the teardown operates on two different accounts. | `osc/tear_down_outscale.sh:109,117` | Add `--profile "$OAPI_PROFILE"`. |
| T-04 | 🟠 | **Teardown reports success even when it failed.** Most deletes end in `|| true`, so a security group still in use (or a `DeleteNet` failure) leaves resources behind with exit code `0`. | `osc/tear_down_outscale.sh:99-150` | Keep `|| true` for idempotency but add a final verification pass (`ReadNets` on the Net) and exit non-zero if anything survives. |
| T-09 | 🟠 | **No rollback on partial provisioning failure.** `set -e` aborts mid-run before the `OSC_*` block is written, so already-created resources are both orphaned *and* unrecorded — teardown cannot find them. | `osc/osc-setup.sh` | Write each ID to `_my_env.sh` as it is created, or trap `ERR` and tear down what exists. |
| T-05 | 🟠 | **Tarball selection and version parsing both fail toward the wrong answer.** `ls … | head -n 1` silently picks the alphabetically first tarball (usually the *older* version) when several are present; and if the filename does not match the regex, `sed` returns the basename unchanged and non-empty, so the `-z` guard never fires. | `build_and_deploy_redis_image_with_packer.sh:10-23` | Fail when more than one tarball matches; validate `REDIS_VERSION` against `^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$`. |
| T-06 | 🟡 | **OMI-ID extraction failures are not propagated.** A missing `manifest.json` only warns and exits `0`; an empty `jq` match appends a blank `OUTSCALE_AMI_ID=`. | `build_and_deploy_redis_image_with_packer.sh:56-63` | Assert the ID matches `^ami-[0-9a-f]+$` and exit non-zero otherwise. |
| T-07 | 🟠 | **Stale/personal defaults in the HCL.** `redis_version = "7.22.0-95"` (tarball is `8.0.2-41`), `region = "eu-west-1"` while `source_omi = ami-054f16b1` only exists in **eu-west-2**, and `keypair_private_file = "/Users/thomas.manson/.ssh/…"`. `packer build` without the wrapper fails or builds the wrong thing. | `packer/redis_ubuntu_outscale_image.pkr.hcl:12-38` | Remove the defaults and mark the variables required, or align them with reality. |
| T-08 | 🟠 | **Scripts must be run from their own directory.** `source "$(dirname "$0")/../_my_env.sh"` is path-independent, but the *write* target `ENV_FILE="../_my_env.sh"`, `$HCL_FILE` and the tarball glob are all CWD-relative — so running from elsewhere reads the right file and writes the wrong one. | `osc-setup.sh:214`; `build_and_deploy…:6,8,10` | Derive everything from `$(cd "$(dirname "$0")/.." && pwd)`. |
| T-10 | 🟠 | **Base OMI pinned by raw region-specific ID** (`ami-054f16b1`, eu-west-2, snapshot 2025-07-07). Outscale will deregister it eventually and the build breaks for a non-obvious reason. | `packer/…pkr.hcl:36` | Look the base OMI up by name/owner filter, or document a review cadence. |
| T-12 | 🟠 | **Time sync is unasserted.** `ntp=no`, and the installer prints *"NOT auto-configuring NTP, please manually synchronize cluster node clocks"*. Clock skew breaks a RE cluster. It works today only because Ubuntu's `systemd-timesyncd` happens to be installed and restarted. | `redis-install-answers.txt:3` | Assert `timedatectl show -p NTPSynchronized` in the build; document Outscale's NTP source. See ADR 0008. |
| T-16 | 🟠 | **Private-IP detection is hardcoded to `10/8`** and breaks on a multi-address VM (`internal_ip` becomes multi-line, corrupting `/etc/hosts`). Masked today only because `osc-setup.sh` hardcodes `10.0.0.0/16`. | `create-or-join-redis-cluster.sh:19-20` | Match any RFC1918 range and take the first address. Executing copy is in `-Run`. |
| T-17 | ⚫ | **Resolved — Redis Flex does work; the earlier reading of Build in isolation was wrong.** `Run/osc/instanciate_image_outscale.sh` attaches two `io1` volumes (`/dev/sdf`, `/dev/sdg`); `Run/osc/cluster_instanciate.sh` installs a udev rule forcing `queue/rotational=0` (Outscale mis-detects `io1` as rotational), runs `/opt/redislabs/sbin/prepare_flash.sh -y` for the RAID0, and only then does `rladmin` receive `flash_enabled`. Commit `34c7939`'s complaint was fixed by `699110c` "Flex working on outscale" (2025-09-10). | `Run/osc/*.sh` | **No action.** The Build image correctly prepares nothing for flash — volume geometry is a deployment choice. Recorded so it is not re-flagged. |
| T-29 | 🟡 | **Three internal Redis Enterprise ports are missing from the SG**: `8444` (web proxy ↔ `cnm_http`/`cm`), `3357` (internal communication), `8000` (internal metrics). | `osc/osc-setup.sh:169-185` | Cross-checked against the Redis port matrix. Likely cause of intermittent UI/metrics oddities. |
| T-30 | 🟡 | **No API-response validation.** Resource IDs are read with `jq -r` and never checked; an API error yields the literal string `null`, which then flows into the next call and into `_my_env.sh`. | `osc/osc-setup.sh` throughout | Guard each extraction (`[[ "$NET_ID" =~ ^vpc- ]]`). |

## Image size / hygiene

| ID | Sev | Item | Where |
|---|---|---|---|
| T-31 | 🟡 | **~2 GB of installer payload baked into the OMI**: `/home/outscale/redis-enterprise.tar` (993 MB), the extracted `redis-enterprise/` tree, `/home/outscale/.gnupg`, `/etc/resolv.conf.orig`, and no `apt-get clean`. On a 30 GB root. | `prepare-and-install-redis-install.sh` (missing cleanup) |
| T-18 | ⚪ | **OMI name still says `-aws-`**: `packer-redis-enterprise-8.0.2-41-ubuntu-22-lts-aws-20251125-1439`. AWS was dropped in `2e95621`. `.gitignore` also still lists `aws/setup-aws-output.txt` and `build_scripts/ec2_ubuntu_base_for_redis_enteprise.pem`. | `packer/…pkr.hcl:45`; `.gitignore:38,41` |
| T-32 | ⚪ | `.gitignore` **ignores itself** (line 40 is `.gitignore`). Harmless — it is already tracked — but confusing. | `.gitignore:40` |
| T-33 | ⚪ | `build_scripts/packer.out` (343 KB) and `manifest.json` are git-ignored, but `manifest.json` is **required** by the wrapper to extract the OMI ID. Losing it loses build history. | `.gitignore:36-37` |

## Dead code / duplication

| ID | Sev | Item | Where |
|---|---|---|---|
| T-14 | 🟠 | **`image_scripts/create-or-join-redis-cluster.sh` is dead code here** — byte-identical to the `-Run` copy, which is the only one executed (`-Run/osc/cluster_instanciate.sh`). The Packer template never uploads it. Two copies will drift, and T-15/T-16/T-17 would then need fixing twice. | `image_scripts/create-or-join-redis-cluster.sh` |
| T-34 | ⚪ | `safe_unlink_route_table()` is **defined but never called**; step 3/7 unlinks by `LinkRouteTableId` instead. | `osc/tear_down_outscale.sh:76-82` |
| T-35 | ⚪ | `pause()` is a no-op (the `read -rp` was commented out in `a7b309a`); 11 call sites now just print a blank line. | `osc/osc-setup.sh:20-23` |
| T-36 | ⚪ | `//todo generate & register keypair` — the keypair must be created by hand per the README. | `packer/…pkr.hcl:72` |

## Tooling / process

| ID | Sev | Item |
|---|---|---|
| T-25 | 🟠 | **No tests, no linter config, no CI.** Nothing prevents a regression. Minimum viable: a CI job running `shellcheck` + `packer fmt -check` + `packer validate` (all credential-free), plus a `bats` test for the version-parsing regex and the teardown's variable assertions. |
| T-37 | 🟡 | **`packer` is not installed in the Colima VM**, so `packer fmt`/`validate`/`init` — all credential-free, same posture as `tofu validate` — cannot run here. Add it to `scripts/vm-provision.sh`, then `./03-vm-up.sh`. `oapi-cli` should stay host-only by design. |
| T-38 | 🟡 | **README is out of date on three points**: it calls the build script `build_and_deploy_image_with_packer.sh` (actual: `build_and_deploy_redis_image_with_packer.sh`), shows an `outscale` argument (only `-debug` is parsed), and documents the generated variables as `VPC_ID`/`IGW_ID`/`SUBNET1`/`AZ1` (actual: `OSC_NET_ID`/`OSC_IGW_ID`/`OSC_SUBNET1`/`OSC_AZ1`). |
| T-39 | ⚪ | `shellcheck` exits **1** on the five shell files: 2 warnings — `SC2207` (`VM_IDS=($(…))`, `tear_down_outscale.sh:87`) and `SC2206` (`args+=($BUILD_OPTS)`, `build_and_deploy_redis_image_with_packer.sh:49`) — plus 5 info findings (3× `SC1091` on the `_my_env.sh` source, `SC2012` `ls` vs `find` at build:10, 2× `SC2317` unreachable `exit 1`). No errors; none changes behaviour today. Also `SC2148` (no shebang) if `_my_env.template.sh` is included in the run. |

---

## Recommended order

1. **T-01** — stop orphaning billable Nets (rewrite the state block, guard re-runs).
2. **R-01 + R-02** (`docs/findings.md`) — delete the duplicated `osc-setup.sh`,
   `tear_down_outscale.sh` and `create-or-join-redis-cluster.sh` from Build. They are
   byte-identical to Run's copies, Build never uses them, and they are where T-21/T-40/T-15 would
   otherwise have to be fixed twice.
3. **T-15 + T-14** — stop leaking the admin password; delete the duplicate script from this repo.
4. **T-11 + T-31** — de-identify and slim the image.
5. **T-02, T-03, T-04** — make teardown terminate, use one profile, and tell the truth.
6. **T-19, T-20, T-22, T-23** — restore host hardening, each validated by `rlcheck` + a real cluster.
7. **T-25 + T-37** — add the lint/validate CI gate so none of the above regresses.
