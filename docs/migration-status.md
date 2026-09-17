# Migration status — Augment handover → Claude Code agent docs

**Date:** 2026-09-16 · **Repo state:** `main` @ `fe7c72f` (2025-11-25), working tree clean

## 1. ⚠️ The handover folder does not exist

The task specified a `handover/` folder containing `STATE.md`, `MEMORY.md`, `DECISIONS.md`,
`PRD.md`, `ARCHITECTURE.md`, `FEATURES.md` and `GUIDELINES.md`. **None of it is present.**
Searched:

| Where | Result |
|---|---|
| Working tree (`find`, `fd -H -t d handover`) | not found |
| Entire git history (`git log --all --diff-filter=A -- 'handover*' '*STATE.md' '*DECISIONS.md' …`) | never committed |
| All branches (`git branch -a`) | only `main` and `origin/main` |
| `$HOME` (`fd -H -t d 'handover' /Users/thomas.manson`) | not found anywhere |
| Tracked Markdown (`git ls-files | grep md`) | `README.md` only |

**Confirmed by the maintainer on 2026-09-16: the handover folder never existed.** The earlier
work was done with ChatGPT and left no handover artefacts. So there is nothing to reconcile and
nothing outstanding on this point.

**Every document here is therefore derived from the actual code, config, git history and the real
build log** — which the ground rules define as the truth anyway. Two consequences: the provenance
column below is uniformly "code", and any *intent* that was never written into the code is
reconstruction, flagged in §5.

## 2. What was produced

| File | Derived from |
|---|---|
| `CLAUDE.md` | All 10 tracked files; verified commands; `packer.out`; global `~/.claude/CLAUDE.md` referenced, not restated |
| `docs/product/PRD.md` | Repo purpose + README + git history + the Outscale/SecNumCloud context you gave |
| `docs/architecture/overview.md` | The HCL, the three shell scripts, `packer.out`, and the `-Run` repo for the boundary; 4 mermaid diagrams |
| `docs/specs/outscale-network-provisioning.md` | `osc/osc-setup.sh` |
| `docs/specs/outscale-network-teardown.md` | `osc/tear_down_outscale.sh` |
| `docs/specs/packer-image-build.md` | `build_scripts/*.sh` + `packer/*.pkr.hcl` + `manifest.json` + `packer.out` |
| `docs/specs/image-preparation-and-redis-install.md` | `image_scripts/prepare-and-install-redis-install.sh` + `redis-install-answers.txt` + `packer.out` |
| `docs/specs/cluster-create-or-join.md` | `image_scripts/create-or-join-redis-cluster.sh` (flagged as dead code here) |
| `docs/adr/0001`–`0009` | Decisions reconstructed from code + commit messages; each ADR cites its evidence |
| `docs/TODO.md` | Code audit, README §TODO, `//todo`, commit admissions, `shellcheck`, Redis port matrix |
| `.claude/settings.json` | Credential-free tools allowed; `oapi-cli`, `packer build`, `git push` and secret paths denied — mirrors the global security model |

Five features were identified rather than the handover's list: network provisioning, network
teardown, image build, image preparation + Redis install, and cluster create-or-join.

## 3. Verified

Ran in the VM:

- `shellcheck` on all five shell files → **exit 1**: 2 warnings (`SC2207`, `SC2206`) and
  5 info findings (3× `SC1091`, `SC2012`, 2× `SC2317`). No errors, and none of the findings
  changes behaviour today. Recorded as T-39.
- `jq -e .` on `build_scripts/manifest.json` → valid; 6 builds, `last_run_uuid` consistent
- `diff` of `image_scripts/create-or-join-redis-cluster.sh` against the `-Run` copy →
  **byte-identical**
- `git log --all`, `git branch -a`, `git ls-files` → 15 commits, one branch, 10 tracked files

Read out of the real build log (`build_scripts/packer.out`, 2025-11-25):

- Built version **8.0.2-41**, artefact **`eu-west-2:ami-06426132`**, image
  `packer-redis-enterprise-8.0.2-41-ubuntu-22-lts-aws-20251125-1439`
- `rlcheck` → **`ALL TESTS PASSED`**, then `Installation complete.`
- GPG key `EC5EC593D7D1529F` "Redis Labs Package Signing Key (2020)" imported into
  `/home/outscale/.gnupg` — which proves `sudo -E` preserves `HOME=/home/outscale`
- The installer's own warning: *"NOT auto-configuring NTP, please manually synchronize cluster
  node clocks"*; `systemd-timesyncd` present and restarted
- `Removed /etc/systemd/system/sysinit.target.wants/apparmor.service` — AppArmor disable
  confirmed executing
- **Zero** matches for `cloud-init clean`, `machine-id` or `ssh_host_` → T-11 confirmed by absence
- The 993 MB tarball uploaded and never deleted → T-31 confirmed

Cross-checked against Redis documentation (redis-docs MCP):

- [Network port configurations](https://redis.io/docs/latest/operate/rs/networking/port-configurations/)
  → used to classify every SG rule Internal/External and to find the three missing internal
  ports (T-29)
- [Product lifecycle](https://redis.io/docs/latest/operate/rs/installing-upgrading/product-lifecycle/)
  → Redis Enterprise 8.0 GA Oct 2025, EOL **2028-07-31**; the pinned version is current

## 4. Conflicts found, and how they were resolved

No handover to conflict with, so these are **code vs README/comments** — code won in every case.

| # | Claim | Reality | Resolution |
|---|---|---|---|
| 1 | README: run `./build_and_deploy_image_with_packer.sh outscale` | File is `build_and_deploy_redis_image_with_packer.sh`; the only argument parsed is `-debug` | Documented the real name/argument; README fix is T-38 |
| 2 | README: setup appends `VPC_ID`, `IGW_ID`, `SUBNET1`, `AZ1`… | Actually `OSC_NET_ID`, `OSC_IGW_ID`, `OSC_SUBNET1`, `OSC_AZ1`… | Documented the real names; T-38 |
| 3 | HCL `variable "redis_version" { default = "7.22.0-95" }` | Tarball and last build are `8.0.2-41`; the wrapper overrides it | Documented as a stale default that breaks a direct `packer build`; T-07 |
| 4 | HCL `variable "region" { default = "eu-west-1" }` with `source_omi` commented *"eu-west-2"* | The OMI ID is region-specific and only exists in eu-west-2 | Flagged as a latent misconfiguration; T-07 |
| 5 | OMI name contains `-aws-` | Builder is `outscale-bsu`; AWS removed in `2e95621` | Cosmetic leftover; T-18 |
| 6 | `image_scripts/create-or-join-redis-cluster.sh` sits in this repo | Never uploaded by the Packer template; only `-Run` executes it; byte-identical duplicate | Spec written but marked **dead code**; recommend deleting it here; T-14 |
| 7 | Code comment: SSH hardening *"somehow, this wasn't working on Outscale"* | Not Outscale. Ubuntu cloud images ship `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`, processed via `Include` before the main file, so its directives beat `sed` edits to `sshd_config` | Root cause documented with the correct fix (a drop-in file); T-22 |
| 8 | README implies the setup/teardown pair is re-runnable, with a note to "remove the generated values" | `osc-setup.sh` is not idempotent and `_my_env.sh` **already holds two `OSC_*` blocks**, so one Net is currently orphaned and billing | Elevated from a README footnote to the top-severity item; T-01 |
| 9 | `.gitignore` lists `manifest.json` as ignorable | The build wrapper **requires** it to extract the OMI ID | Documented as "keep locally"; T-33 |

## 5. Still inferred — verify

With no handover to corroborate them, the ADR *rationales* are the weakest part of this set: the
code proves **what** was decided, never **why**. Items 2-4 below are the ones to challenge.

Flagged wherever it appears; listed here so nothing hides:

1. **Resolved 2026-09-16.** The PRD's commercial framing and the customer-facing / SecNumCloud
   delivery posture are confirmed by the maintainer. The hardening items are release blockers.
2. **(inferred — verify)** ADR 0006's premise, that AppArmor was disabled because it interfered
   with Redis Enterprise. The line has been present since the first commit with no comment and
   no commit message explaining it. It may simply be precautionary and removable.
3. **(inferred — verify)** ADR 0005's premise, that UFW was deferred to get a first build
   working. Consistent with the README TODO and the code being commented rather than deleted,
   but never stated.
4. **(inferred — verify)** ADR 0004's rationale for shell over Terraform. The *absence* of any
   `.tf` is a fact; the reasons are reconstruction.
5. **(inferred — verify)** Acceptance criterion 4 in the PRD (a 3-node rack-aware cluster
   reaching `active`) is owned by `-Run` and not observable from this repo.
6. **(inferred — verify)** T-29's three missing SG ports (`8444`, `3357`, `8000`) come from
   comparing the script to Redis's published matrix. Whether their absence causes a *visible*
   symptom on a live cluster is untested.
7. **(inferred — verify)** T-11's impact. The build log's silence proves no de-identification
   step ran; that shared SSH host keys actually persist into a launched VM (rather than being
   regenerated by Outscale's cloud-init) should be confirmed on a running instance:
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on two VMs from the same OMI.
8. **(inferred — verify)** T-24: whether removing `unattended-upgrades` is deliberate policy
   ("patch by re-baking") or an oversight.

## 6. Recommended next 3 actions

1. **Fix `_my_env.sh` state handling (T-01).** Rewrite the generated block in place between
   sentinels instead of appending, and have `osc-setup.sh` refuse to run when a live
   `OSC_NET_ID` is present unless `--force`. Then reconcile the two blocks currently in
   `_my_env.sh` and tear down the orphaned Net (`vpc-0e525ede` / `sg-d7e6ad50` — the earlier
   block) from the host. This is costing money right now and it blocks every other change,
   because the state file is how all three scripts and the `-Run` repo communicate.

2. **Parameterise the SG source CIDR (T-21, T-40) and stop the password leak (T-15).** The port
   list is correct — clients need the database ports, the UI and the API — but the source is
   hardcoded `0.0.0.0/0`, so the customer cannot express the exposure they actually want (for
   SecNumCloud, very likely none). Add `OPERATOR_CIDR`/`CLIENT_CIDR` defaulting to the Net CIDR,
   and drop the cleartext REST API `8080` since `9443` already covers it. In the same pass, fix
   the admin password appearing in `ps` output and in cleartext in
   `/var/log/redis-enterprise-init.log` — in `-Run`, which owns the executing copy — and delete
   the dead duplicate here (T-14). Both the SG and that script are Run-phase concerns, so plan
   the change across the two repos together.

3. **Add the credential-free CI gate (T-25, T-37).** Add `packer` to
   `scripts/vm-provision.sh`, then a CI job running `shellcheck` + `packer fmt -check` +
   `packer validate`. None of it needs Outscale credentials, so it runs in the VM and in GitHub
   Actions. Without it, the ~20 fixes above will regress silently — there is currently no test,
   no linter config and no CI in this repo.

Then work `docs/TODO.md` §Recommended order, which continues with image de-identification
(T-11/T-31) and restoring host hardening (T-19/T-20/T-22/T-23) — each validated by `rlcheck`
plus a real 3-node cluster, since that is the only way to tell a safe hardening step from one
that breaks Redis Enterprise.
