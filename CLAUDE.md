# CLAUDE.md — OSC-RedisEnterprisePacker-Build

> Global engineering standards, the security model (build in the VM, git + deploy from the
> host, no credentials in the VM) and the brainstorm→spec→plan→ship→deploy loop live in
> `~/.claude/CLAUDE.md`. **This file does not restate them.** It documents only what is
> specific to this repository.

## What this is

Packer tooling that bakes a **Redis Enterprise Software golden image (OMI)** for
**Outscale** (French sovereign cloud, SecNumCloud-qualified, Dassault subsidiary), plus the
shell scripts that provision and tear down the Outscale network scaffolding the build needs.

**Scope boundary — this repo is BUILD only.** It produces an OMI ID. Launching VMs from that
image and forming the Redis Enterprise cluster is the sibling repo
[`OSC-RedisEnterprisePacker-Run`](https://github.com/dev-mansonthomas/OSC-RedisEnterprisePacker-Run)
(`~/Projects/OSC-RedisEnterprisePacker-Run`). Runtime configuration is deliberately *not*
baked in, so one image fits every customer.

## Stack

| Layer | Technology | Notes |
|---|---|---|
| Image build | HashiCorp Packer ≥ 1.7, < 2.0 | plugin `github.com/outscale/outscale` ≥ 1.0.0 (v1.5.0 used in the last build) |
| Builder | `outscale-bsu` | BSU = Outscale's EBS equivalent |
| Cloud API | `oapi-cli` (Outscale API CLI) | profile `default` from `~/.osc/config.json` |
| Guest OS | Ubuntu 22.04 LTS (Jammy) | source OMI `ami-054f16b1` (eu-west-2, 2025.07.07) |
| Payload | Redis Enterprise Software `8.0.2-41` | `redis-software/redislabs-8.0.2-41-jammy-amd64.tar` (993 MB, git-ignored) |
| Glue | Bash 5.x / zsh + `jq` | no Terraform/OpenTofu, no Python, no CI |
| Tests | **none** | no test suite, no linter config, no CI workflow — see `docs/TODO.md` |

Redis Enterprise 8.0 lifecycle: GA Oct 2025 → EOL **2028-07-31**
([product lifecycle](https://redis.io/docs/latest/operate/rs/installing-upgrading/product-lifecycle/)).

## Install / build / run / test — verified commands

### Prerequisites (host, not the VM — all of these need Outscale credentials)

```sh
brew tap hashicorp/tap && brew install hashicorp/tap/packer
brew tap outscale/tap  && brew install outscale/tap/oapi-cli
brew install jq
```

Credentials (host shell profile + `~/.osc/config.json`, region `eu-west-2`):

```sh
export OSC_ACCESS_KEY=...   # consumed by Packer
export OSC_SECRET_KEY=...
oapi-cli ReadVms            # smoke test
```

Then `cp _my_env.template.sh _my_env.sh` and set `OWNER`, `OUTSCALE_REGION`,
`OUTSCALE_SSH_KEY`. `_my_env.sh` is git-ignored and is the **shared state file** between all
three scripts (see *Gotchas*).

### The three commands, in order

```sh
# 1. Provision the Outscale Net / IGW / route table / 3 subnets / security group
cd osc/         && ./osc-setup.sh

# 2. Build the OMI  (optional: -debug  →  packer -debug -on-error=ask)
cd build_scripts/ && ./build_and_deploy_redis_image_with_packer.sh

# 3. Destroy everything created in step 1 (and any VM still in the Net)
cd osc/         && ./tear_down_outscale.sh
```

All three **must be run from their own directory** — they use relative paths
(`../packer/…`, `./manifest.json`, `../_my_env.sh`).

### What can be verified inside the VM

`packer` and `oapi-cli` are **not installed in the Colima VM** and every command above needs
Outscale credentials, so the build is a **host-side action**. Credential-free checks that do
run in the VM:

```sh
shellcheck osc/*.sh build_scripts/*.sh image_scripts/*.sh   # exits 1: 2 warnings + 5 info, see T-39
jq -e . build_scripts/manifest.json                                   # manifest well-formed
# packer fmt -check packer/ ; packer validate packer/…pkr.hcl         # once packer is in the VM
```

> `packer` is missing from `scripts/vm-provision.sh`. Add it — `packer fmt`/`validate`/`init`
> are credential-free and belong in the VM (same posture as `tofu validate`). `oapi-cli` stays
> host-only by design.

### Success criteria

`build_scripts/manifest.json` gains a new `builds[]` entry, `last_run_uuid` points at it, and
`OUTSCALE_AMI_ID=ami-xxxxxxxx` is appended to `_my_env.sh`. Last known-good run:
**2025-11-25, `eu-west-2:ami-06426132`**, image
`packer-redis-enterprise-8.0.2-41-ubuntu-22-lts-aws-20251125-1439`, `rlcheck` → `ALL TESTS PASSED`.

## Module map

| Path | Responsibility |
|---|---|
| `osc/osc-setup.sh` | Creates the Outscale Net (`10.0.0.0/16`), Internet Service, route table + default route, 3 public subnets (`10.0.{10,20,30}.0/24` in AZ a/b/c, `MapPublicIpOnLaunch`), and the security group with the full Redis Enterprise port matrix. **Appends** the generated IDs to `_my_env.sh`. |
| `osc/tear_down_outscale.sh` | Reverse order teardown: terminate VMs in the Net → delete default route → unlink route table → delete RTB, SG, Internet Service, subnets, Net. Reads IDs from `_my_env.sh`. |
| `build_scripts/build_and_deploy_redis_image_with_packer.sh` | Wrapper: derives `REDIS_VERSION` from the tarball filename, runs `packer init`/`validate`/`build` with `PACKER_LOG=1`, then extracts the OMI ID from `manifest.json` and appends it to `_my_env.sh`. |
| `packer/redis_ubuntu_outscale_image.pkr.hcl` | The `outscale-bsu` source + build: 30 GB gp2 root, uploads the provisioning script, the answer file and the 993 MB tarball, then runs the script as root. `force_deregister`/`force_delete_snapshot` make rebuilds idempotent. |
| `image_scripts/prepare-and-install-redis-install.sh` | Runs **inside** the build VM as root: apt upgrade, umask, utilities, swap off, purge `snapd`/`apport`/`unattended-upgrades`, disable the systemd-resolved stub listener, disable AppArmor, verify the `.deb` GPG signature, widen the ephemeral port range, then `install.sh -c redis-install-answers.txt`. |
| `image_scripts/redis-install-answers.txt` | Unattended answers for Redis Enterprise `install.sh`: `systune=yes`, `rlcheck=yes`, `firewall=no`, `ntp=no`, `ignore_swap=no`. |
| `build_scripts/manifest.json`, `build_scripts/packer.out` | Build artefacts. Listed in `.gitignore` but `manifest.json` is *needed* by the wrapper — keep it locally. |
| `_my_env.sh` / `_my_env.template.sh` | Local config + append-only generated state. Git-ignored. |
| `redis-software/` | Drop the Redis Enterprise Jammy tarball here. Git-ignored except `SHA256SUMS`. |
| *(removed)* | `image_scripts/create-or-join-redis-cluster.sh` was deleted in PR 2 — it was never part of the image (the Packer template uploads only the provisioning script, the answers file and the tarball). The live copy belongs to `-Run`. Don't re-add it here. |

## Conventions

- **Bash, `set -euo pipefail`, `#!/usr/bin/env bash`.** Keep it POSIX/bash-portable.
- **Comments and user-facing script output are in French**; identifiers, docs and commit
  messages in English. Match the file you are editing.
- `oapi-cli` is always called with `--profile "$OAPI_PROFILE"`. Two calls in
  `tear_down_outscale.sh` (lines 109, 117) violate this — fix them rather than copying them.
- Config flows one way: `_my_env.sh` → scripts. Scripts only ever **append** to it.
- Outscale naming: `Net` = VPC, `Internet Service` = IGW, `Subregion` = AZ, `OMI` = AMI,
  `BSU` = EBS. Variables are prefixed `OSC_` for generated IDs, `OUTSCALE_` for user config.
- Packer variables are passed by the wrapper (`-var region=… keypair_private_file=…
  redis_version=…`); the defaults in the `.pkr.hcl` are **stale and personal** — never rely on them.
- `shellcheck` currently exits 1 with two warnings (`SC2207` teardown:87, `SC2206`
  build:49) and five info findings — see TODO T-39. Do not add new ones; fixing the
  existing two is welcome.

## Gotchas

1. **`osc-setup.sh` is not idempotent and its state file is append-only.** A second run
   creates a *whole new* Net and appends a second `OSC_*` block to `_my_env.sh`. Sourcing keeps
   the last block, so `tear_down_outscale.sh` deletes only the newest set — the earlier Net,
   subnets and SG are **orphaned and still billed**. `_my_env.sh` already contains two blocks
   today. Same for `OUTSCALE_AMI_ID` on repeated builds. Prune the file by hand between runs.
2. **`tear_down_outscale.sh:46` loops forever** (`while :;` with no `tries` ceiling) if a VM
   never reaches `terminated`. Ctrl-C and clean up in the Cockpit.
3. **Stale defaults in the `.pkr.hcl`**: `redis_version = "7.22.0-95"` (tarball is `8.0.2-41`),
   `region = "eu-west-1"` while `source_omi = ami-054f16b1` only exists in **eu-west-2**, and
   `keypair_private_file` hardcodes `/Users/thomas.manson/…`. Running `packer build` directly
   instead of the wrapper fails or builds the wrong thing. Set `OUTSCALE_REGION=eu-west-2`.
4. **The OMI name says `-aws-`** (`packer-redis-enterprise-…-ubuntu-22-lts-aws-…`) even though
   the builder is Outscale. Cosmetic leftover from the AWS era (dropped in `2e95621`).
5. **The 993 MB tarball and its extracted tree are never removed** from the build VM, so they
   are baked into the OMI (~2 GB of the 30 GB root). No `apt-get clean` either.
6. **No image de-identification**: the build performs no `cloud-init clean`, does not remove
   `/etc/ssh/ssh_host_*` or reset `/etc/machine-id`. Every VM launched from the OMI therefore
   shares the same SSH host keys and machine-id — verified absent from `build_scripts/packer.out`.
7. **Host hardening is off by design-so-far**: `firewall=no`, the whole UFW block is commented
   out, AppArmor is disabled, the SSH-hardening `sed`s are commented out ("somehow, this wasn't
   working on Outscale" — it fails because Ubuntu cloud images override `sshd_config` from
   `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`), and `auditd` is not installed.
   Security rests entirely on the Outscale security group. See `docs/TODO.md` §Security.
8. **`osc/osc-setup.sh` and `osc/tear_down_outscale.sh` are byte-identical to Run's copies and
   the build never uses them** — the Packer Outscale plugin creates and destroys its own
   temporary security group (confirmed in `packer.out`). The **customer-facing** security group,
   and therefore the exposure/CIDR decision, belongs to `Run/osc/osc-setup.sh`. Do not
   "harden the SG" here; the right change is to delete these two files from Build
   (`docs/findings.md` R-01). Redis Enterprise's port list itself is correct and required.
9. **`ntp=no`** — Redis Enterprise's installer explicitly warns *"NOT auto-configuring NTP,
   please manually synchronize cluster node clocks."* Clock skew breaks a RE cluster. In
   practice Ubuntu's `systemd-timesyncd` is present and running (confirmed in `packer.out`),
   but nothing in this repo asserts that.
10. **GPG verification is circular**: the script imports
    `redis-enterprise/rlec_install_utils_tmpdir/GPG-KEY-redislabs-packages` *from inside the
    tarball* and then verifies the `.deb` against it. A tampered tarball supplies both. There is
    no checksum check on the tarball either. Pin Redis's key fingerprint out-of-band
    (`EC5EC593D7D1529F` was the key seen in the last build).
11. `.gitignore` ignores **itself** (`.gitignore` on line 40) — harmless since it is already
    tracked, but confusing.
12. `image_scripts/` filename is `prepare-and-install-redis-install.sh`; the build wrapper is
    `build_and_deploy_redis_image_with_packer.sh` (the README's
    `build_and_deploy_image_with_packer.sh outscale` is wrong on both name and argument — the
    only accepted argument is `-debug`).

## Confirmed project decisions

- **Delivery posture: customer-facing / SecNumCloud** (2026-09-16). Outscale customers will audit
  and reproduce this build, so the hardening gaps in `docs/TODO.md` §Security are **release
  blockers**, not backlog. Do not treat this repo as a throwaway lab.
- **Network exposure is the customer's decision.** Redis Enterprise's port list is required and
  must not shrink; what must become configurable is the *source CIDR*. For a SecNumCloud
  deployment the nodes are very likely **not** internet-facing.
- **Auto Tiering / Redis Flex works — don't "fix" it.** Run attaches two `io1` volumes, forces
  `queue/rotational=0` via udev (Outscale mis-detects `io1` as rotational), and runs
  `prepare_flash.sh -y` before `rladmin` gets `flash_enabled`. The Build image correctly prepares
  nothing for flash. See TODO T-17.
- **Exposure is the customer's decision, made in Run.** Redis Enterprise's port list is required
  and must not shrink; what needs a knob is the *source CIDR*, in `Run/osc/osc-setup.sh`
  (`docs/findings.md` F-02).
- **There was never an Augment/ChatGPT `handover/` folder.** The agent docs were reconstructed
  from code, git history and the build log; see `docs/migration-status.md`.

## Agent docs

- `docs/product/PRD.md` — problem, users, scope
- `docs/architecture/build-and-run-overview.md` — **start here**: end-to-end Build→OMI→Run
- `docs/architecture/overview.md` — this repo's internals, with diagrams
- `docs/findings.md` — **what to improve in this repo**, prioritised
- `docs/handover-run-findings.md` — Run-phase findings, **parked**; do not fix them from here
- `docs/specs/*.md` — per-script contracts (inputs, outputs, edge cases, acceptance criteria)
- `docs/adr/*.md` — decisions and why
- `docs/plan/build-remediation.md` — **the implementation plan** (phases, VM vs host, gates)
- `docs/TODO.md` — open work, severity-tagged
- `docs/migration-status.md` — provenance of these docs and what is still unverified
