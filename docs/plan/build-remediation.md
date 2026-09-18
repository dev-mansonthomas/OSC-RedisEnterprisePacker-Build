# Implementation plan — Build remediation

Covers every open Build finding in `docs/findings.md`. Run-phase items stay parked in
`docs/handover-run-findings.md`.

**Written 2026-09-17.** Ordered so that cheap/safe work lands first, the CI gate arrives before
the risky changes, and nothing is done twice.

## Constraints that shape the plan

1. **The VM cannot build.** `packer` and `oapi-cli` are absent and the build needs Outscale
   credentials. Everything credential-free (lint, `packer validate`, the version/download
   tooling, unit tests) is verifiable here; **every image change needs a host-run build**, and
   the hardening steps additionally need a real 3-node cluster from `-Run`. Each phase below is
   marked **[VM]** or **[HOST]** accordingly.
2. **No test suite exists.** Phase 0 creates the harness, so later phases have something to
   assert against — otherwise the ~20 fixes are unverifiable.
3. **The build must run inside a Net** (maintainer, 2026-09-17) — it needs a VM with IPs and
   internet access. It currently does **not** (`"SubnetId":""` in `packer.out`), so
   `osc-setup.sh` stays in Build and PR 5 wires the build into it (**T-41**).
4. **Build is Outscale-internal**; Run is customer-facing. Build findings are about
   correctness, reproducibility and the *image* we publish — not about customer exposure.
5. Work on a branch off `main`; commit/push only when asked. One PR per step (see below).

---

## Delivery model: one PR per step **(decided 2026-09-17)**

Each PR is independently reviewable, independently revertible, and — where it touches the image
— gated on its own host build. Branch off `main`, never commit to `main`, and the PR body goes
to `debug/git/pr-body.md` for `git-pr-merge` on the host.

`[VM]` = fully verifiable in the Colima VM. `[HOST]` = needs a host-run Packer build (Outscale
credentials). `[HOST+RUN]` = additionally needs a real 3-node cluster from
`OSC-RedisEnterprisePacker-Run`.

---

### PR 1 — CI harness and lint baseline ✅ **DONE 2026-09-17** `[VM]`

No behaviour change. Everything after this depends on it.

- `packer` into `scripts/vm-provision.sh` (**T-37**), then `./03-vm-up.sh`
- `scripts/lint.sh` = `shellcheck` + `packer fmt -check` + `packer validate` + the Build/Run
  `diff` guard
- Fix **T-39**: `SC2206` (`args+=($BUILD_OPTS)` → array), `SC2207` (`mapfile`)
- `tests/` harness (bats or plain asserts), seeded with: version-regex parsing, OMI-ID
  extraction, `_my_env.sh` block rewriting
- GitHub Actions workflow running both — credential-free, identical in CI and in the VM (**T-25**)

**Gate:** `scripts/lint.sh && tests/run.sh` green.

### PR 2 — Deletions and hygiene ✅ **DONE 2026-09-17** `[VM]`

- `git rm image_scripts/create-or-join-redis-cluster.sh` (**R-02**, confirmed)
- `.gitignore`: drop the self-reference and dead AWS entries; note that `manifest.json` must be
  kept locally (**T-32**, **T-18** partial, **T-33**)
- Reconcile the `sleep 15` divergence between Build's and Run's `tear_down_outscale.sh`; enable
  the `diff` guard (**R-01**)

**Gate:** lint green; `git grep -c create-or-join` → 0.

### PR 3 — Version detection and download ✅ **DONE 2026-09-17** `[VM]`

Self-contained and credential-free. Delivers the biggest day-to-day win.

- `build_scripts/lib/redis_version.sh` — vendored scraper, fixing three inherited bugs:
  `local x=$(...)` masks the exit status (so the original's `$?` checks never fire), no
  `-o pipefail`, no `curl` timeout. Distinct exit code for "page layout changed".
- `build_scripts/fetch_redis_tarball.sh` — `${BASE}/${MAJ.MIN.PATCH}/redislabs-${FULL}-jammy-amd64.tar`;
  download to `.part` then `mv`; `--continue-at -`; verify received size vs `content-length`
- `redis-software/SHA256SUMS` — record on first download, verify thereafter
- Modes: default warn-only · `--require-latest` · `--download` · `--version X.Y.Z-B`
- Pre-flight in the build wrapper; reject >1 tarball; validate the version string (**T-05**)
- Tests for all of the above

**Gate:** `--version 8.0.2-41` is a no-op against the existing tarball and validates its digest;
`--require-latest` exits non-zero (local 8.0.2-41 < 8.2.0-78). Tests green.

### PR 4 — Wrapper and HCL correctness ✅ **DONE 2026-09-17** `[VM]` + one `[HOST]` smoke build

- Rewrite `_my_env.sh`'s generated block **in place** between
  `# >>> generated (outscale) >>>` / `# <<<` markers, atomically (temp + `mv`); never append.
  Applies to `OUTSCALE_AMI_ID` and to `osc-setup.sh`'s `OSC_*` block. Prune the two stale
  blocks currently in the file (**T-01**)
- Assert the extracted OMI ID matches `^ami-[0-9a-f]+$`; propagate failure (**T-06**)
- `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"`; all paths absolute (**T-08**)
- HCL: remove stale/personal defaults (`redis_version`, `keypair_private_file`); make them
  required; `keypair_name` becomes a variable fed from `_my_env.sh` (**T-07**, **T-36**)
- Drop `-aws-` from `omi_name` (**T-18**)

**Gate:** `packer validate` with no `-var` overrides; one host build succeeds; `_my_env.sh`
holds exactly one generated block.

### PR 5 — Run the build inside the Net `[HOST]` — **POSTPONED (2026-09-17)**

> **Deferred by decision.** Not to be attempted until a build is known-green again after PRs 1-4.
> Rationale: `osc-setup.sh` and the current non-Net build **work today**, and rewiring the
> network is the one change in this plan that could break the build for a reason unrelated to
> everything else. Optimise once there is a working baseline to compare against.
> Tracked as **T-41** in `docs/TODO.md`.

The structural fix behind Q1 — makes `osc-setup.sh` load-bearing instead of decorative.

- HCL: `subnet_id = OSC_SUBNET1`, `subregion_name = OSC_AZ1`, `associate_public_ip_address`
  (or rely on the subnet's `MapPublicIpOnLaunch`), keep `ssh_interface = "public_ip"` (**T-41**)
- Leave the build's security group to Packer's temporary one — correctly scoped to SSH only;
  reusing `OSC_SG_ID` would be *wider* than the build needs
- `README.md`: `osc-setup.sh` becomes a documented prerequisite of the build, not an optional step
- Replace scalar `source_omi` with a **`region → source_omi` map**; wrapper looks up
  `OUTSCALE_REGION`; clear error on an unmapped region. One entry today, the seam for the
  future per-region loop (**T-10**). Record the resolved OMI ID in the manifest.

**Gate:** `packer.out` shows a non-empty `SubnetId` matching `OSC_SUBNET1`; build succeeds;
`rlcheck` still passes.

### PR 6 — Image security, non-breaking `[HOST]`

Nothing here can break Redis Enterprise.

- Pin the Redis GPG key fingerprint and assert it after `gpg --import`, instead of trusting
  whatever the tarball ships (`EC5EC593D7D1529F` observed). With PR 3's digest this closes the
  circular-trust hole (**T-13**)
- Final provisioner step — de-identify: `cloud-init clean --logs`, `rm -f /etc/ssh/ssh_host_*`,
  `truncate -s 0 /etc/machine-id`, `rm -f /var/lib/dbus/machine-id` (**T-11**)
- Final provisioner step — slim: delete the tarball, the extracted tree, `/home/outscale/.gnupg`,
  `/etc/resolv.conf.orig`; `apt-get clean`; `rm -rf /var/lib/apt/lists/*` (**T-31**)
- `timedatectl show -p NTPSynchronized --value` assertion; keep `ntp=no` (**T-12**)

**Gate:** `rlcheck` → `ALL TESTS PASSED`; **two VMs from the OMI have different SSH host keys**
(`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) — the acceptance test for T-11; root usage
down ~2 GB.

### PR 7 — SSH hardening `[HOST+RUN]`

- `/etc/ssh/sshd_config.d/10-hardening.conf` with `PermitRootLogin no`,
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no` — **not** `sed` on the main
  file, which is why it never worked (cloud images ship `60-cloudimg-settings.conf`, `Include`d
  first and therefore winning) (**T-22**)
- Remove the misleading commented block and its "wasn't working on Outscale" comment

**Gate:** `sshd -T | grep -E 'permitrootlogin|passwordauthentication'` correct; `rlcheck` passes;
3-node cluster forms; Run's `scp`/`ssh` still work.

### PR 8 — Audit logging and update policy `[HOST+RUN]`

- Install and enable `auditd` with a minimal ruleset for `/opt/redislabs` and privilege
  escalation (**T-23**)
- Decide and document **T-24**: restore `unattended-upgrades` (security pocket only) **or**
  commit to a documented re-bake cadence. New ADR either way.

**Gate:** `auditctl -l` non-empty; `rlcheck` passes; 3-node cluster forms.

### PR 9 — UFW `[HOST+RUN]` ⚠ medium risk

- Generate the UFW allow-list from the **same port table** as the security group rather than
  hand-maintaining a second list. The committed block is missing `1968`, `3333-3355`, `8002`,
  `8004`, `8006`, `8071`, `9082`, `9091`, `9125`, `36379` — every internode/proxy/envoy port —
  so as written it **cannot** form a cluster. Probable cause of the original failure.
- Move UFW and `firewall=yes` **together**; a mismatch in either direction is the likeliest
  failure mode (**T-19**)

**Gate:** `ufw status verbose` matches the port table; `rlcheck` passes; 3-node cluster forms,
database created and reachable from outside. **Revert rather than debug in place if it fails** —
this is the step most likely to need a second attempt.

### PR 10 — AppArmor experiment `[HOST+RUN]` ⚠ high risk, may end in "no change"

Treat as an experiment, not a cleanup. The git timing (`df62416`, the day Outscale first worked)
suggests it fixed something real.

- Build with AppArmor in `complain` mode; run a 3-node cluster; collect
  `dmesg | grep apparmor` and `/var/log/audit`
- If denials are confined to `/opt/redislabs`: ship an `/etc/apparmor.d/local` profile and
  re-enable enforcement. If unmanageable: keep the disable and **record why in ADR 0006** — that
  outcome is a success too, since the current state has no recorded justification (**T-20**)

**Gate:** either enforcement on with a cluster forming, or a documented reason it stays off.

### PR 11 — Documentation `[VM]`

- `README.md`: correct the script name, the non-existent `outscale` argument, the
  `VPC_ID`/`SUBNET1`/`AZ1` → `OSC_*` variable names; document the version/download flow and the
  `osc-setup.sh` prerequisite (**T-38**)
- New ADRs: region→OMI map, download/digest strategy, `unattended-upgrades` policy, UFW and
  AppArmor outcomes. Update ADRs 0003/0005/0006/0008 with results
- Refresh `docs/findings.md`, `docs/TODO.md`, `docs/architecture/*` to the shipped state

---

## Sequencing summary

| PR | Title | Env | Builds | Cluster | Risk |
|---|---|---|---|---|---|
| 1 | CI harness and lint baseline ✅ | `[VM]` | – | – | none |
| 2 | Deletions and hygiene ✅ | `[VM]` | – | – | none |
| 3 | Version detection and download ✅ | `[VM]` | – | – | none |
| 4 | Wrapper and HCL correctness ✅ *(host build still owed)* | `[VM]`+`[HOST]` | 1 | – | low |
| ~~5~~ | ~~Run the build inside the Net~~ **postponed** | `[HOST]` | 1 | – | low-med |
| 6 | Image security, non-breaking | `[HOST]` | 1 | – | low |
| 7 | SSH hardening | `[HOST+RUN]` | 1 | yes | low |
| 8 | Audit logging + update policy | `[HOST+RUN]` | 1 | yes | low |
| 9 | UFW | `[HOST+RUN]` | 1+ | yes | **medium** |
| 10 | AppArmor experiment | `[HOST+RUN]` | 1+ | yes | **high** |
| 11 | Documentation | `[VM]` | – | – | none |

**PRs 1-3 need no Outscale access at all** and can land back-to-back in one sitting. PRs 4-6 are
one build each. PRs 7-10 are the long pole: four to six builds, each with a real 3-node cluster
validation, and this is where the schedule needs slack.

**Ordering constraints that matter:**
- PR 1 before everything (it is the gate).
- PR 3 before PR 4 — both touch the build wrapper; doing them in the other order means editing
  the same file twice.
- PR 5 is **postponed**; its `region → source_omi` map moves into PR 4 (HCL variable cleanup),
  while the `subnet_id` wiring waits for a green baseline.
- PR 6 before PR 7 — T-11 (host-key regeneration) is the precondition for Run's F-07, and it is
  worth landing before anything that could destabilise SSH.
- PRs 9 and 10 last, and **never stacked** — two unvalidated hardening changes in one build make
  a failure impossible to attribute.

## Status 2026-09-17

PRs 1-4 are implemented on `feat/build-remediation-pr1-4` (5 commits, docs first).
All VM-verifiable gates pass: `scripts/lint.sh` clean, **66 tests** green.

**PR 4's host-build gate is MET.** Build of 2026-09-18 succeeded: `eu-west-2:ami-5e9d1a76`,
Redis Enterprise 8.2.0-78 on base `ami-88dbc914` (`Ubuntu-22.04-2026-08-10`), `rlcheck`
`ALL TESTS PASSED`, `.deb` signature verified, base-OMI auto-resolution and the `old/`
purge both confirmed working. PR 6 is unblocked.

| Finding | State |
|---|---|
| T-05, T-06, T-07, T-08, T-18, T-25, T-32, T-33, T-37*, T-39, R-02 | closed in code |
| T-01 | closed in code; `_my_env.sh` migrated to managed blocks |
| T-10 | region→OMI map in place; multi-region loop still out of scope |
| T-13 | half done (tarball digest); GPG fingerprint pinning is PR 6 |
| R-01 | drift guard in place; baseline records deliberate divergence |
| T-41 | **postponed by decision** |

\* T-37 needs `packer` added to `scripts/vm-provision.sh` in the dev-setup repo —
outside this repository, so it is on you.

## Not in this plan

- Everything in `docs/handover-run-findings.md` (26 Run findings) — different repo.
- **Multi-region publication.** Phase 3.5 creates the seam (a `region → source_omi` map); the
  actual loop over regions, and a per-region network setup, is deliberately out of scope until
  you decide it is needed.
- Redis Flex — verified working, nothing to do (**T-17**).
- Ubuntu 24.04 — not supported by Redis Enterprise; nothing to plan before mid-2027
  (see ADR 0003 for the ESM decision that *will* be needed).
