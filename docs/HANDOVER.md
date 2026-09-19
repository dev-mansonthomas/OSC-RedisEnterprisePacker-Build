# Handover — OSC-RedisEnterprisePacker-Build

For a fresh Claude Code session that will work **only on this repository**.
Written 2026-09-19. Read this, then `CLAUDE.md`, then `docs/findings.md`.

## Where things stand

`main` is at `27bba54` ("Build remediation PR 1-4", squash-merged via PR #1).
Two branches of work exist **on top of it, unmerged**:

| Branch | Content | State |
|---|---|---|
| `feat/image-security-pr6` | PR 6 (GPG pinning, de-identification, payload cleanup, NTP assertion) **and** PR 7's UFW rule set | PR 6 **validated on a real image**; UFW **not yet validated on a cluster** |

Both sets of changes are in that one branch, which was not the plan — PR 7's UFW
work landed there because it was asked for before PR 6 was merged. **Decide first
whether to split it.** Splitting is honest but costs a rebase; keeping it means one
PR whose gate is a cluster test rather than a build test.

```sh
git log --oneline main..feat/image-security-pr6
```

## Gates — run these before anything

```sh
./scripts/lint.sh      # shellcheck · packer fmt/init/validate · drift guard · secret scan
./tests/run.sh         # 239 tests, no network, no credentials
```

**Both must also pass with `_my_env.sh` and the tarball absent** — they are git-ignored,
so that is CI's state, and forgetting it cost two CI failures:

```sh
mkdir -p /tmp/ci && mv redis-software/redislabs-*.tar _my_env.sh /tmp/ci/
./scripts/lint.sh && ./tests/run.sh
mv /tmp/ci/redislabs-*.tar redis-software/ && mv /tmp/ci/_my_env.sh .
```

`packer` was installed by hand in the VM and **is not in `scripts/vm-provision.sh`** of
the `claude-code-dev-setup` repo. On a rebuilt VM it is gone and `lint.sh` loses four of
its eight checks (use `--no-packer`). That fix is outside this repository and belongs to
the maintainer — **do not touch other projects.**

## What is owed right now

**One host build, then a 3-node cluster.** The UFW rule set is the only unvalidated
change, and a bare-node port measurement cannot prove a cluster will form with
`default deny incoming` active. The build must run from the **host** (credentials are
never in the VM):

```sh
cd build_scripts/ && ./build_and_deploy_redis_image_with_packer.sh
```

Then form a cluster with `OSC-RedisEnterprisePacker-Run` and confirm it reaches
`active` with a database reachable from outside. **If it fails, revert rather than debug
in place** — that is what the plan says for this step, and the failure mode is a port
the rule set missed.

While a cluster is up, capture the measurement that is still missing:

```sh
sudo ss -tlnp        # the COMPLETE port set; the recorded one is a bare-node subset
sudo aa-status       # full output; only the first 3 lines were ever captured
```

Add both to `docs/reference/hardening-baseline.md`. PR 10 (AppArmor) needs the second.

## How this repository works

- **Build only.** It produces an OMI ID. Launching VMs and forming clusters is
  `OSC-RedisEnterprisePacker-Run`. Do not fix Run findings here — they are parked in
  `docs/handover-run-findings.md` (27 items) for a session working on that repo.
- **The build runs from the host.** The VM has no Outscale credentials by design. Every
  credential-free check runs in the VM; `packer build` and `oapi-cli` do not.
- **`_my_env.sh` is the interface** to the Run repo. Writers own sentinel-delimited
  blocks and rewrite them **in place** — never append. A stale `OUTSCALE_AMI_ID` launches
  the wrong image.
- **Every path the wrapper reads or writes is overridable** (`MY_ENV_FILE`, `ENV_FILE`,
  `MANIFEST_FILE`, `SUMS_FILE`, `BUILD_LOG_DIR`, `PACKER_OUT_LINK`, …). That is not
  incidental: the test suite runs the real wrapper, and before these existed it clobbered
  `_my_env.sh`, `manifest.json` and a real build log. **Any new path gets the same
  treatment.**
- **The base OMI is resolved at build time**, not pinned. Outscale republishes Ubuntu
  22.04 about every 2 months and prunes after ~10, so a committed ID expires — one
  already did, mid-project. `OUTSCALE_SOURCE_OMI=ami-…` pins it for a Redis-CVE-only
  rebuild.

## Traps that already cost time

1. **`ls` exits 2 on an unmatched glob**, and `set -o pipefail` propagates it. This
   aborted `lint.sh` in CI with no message at all. Use `nullglob` arrays.
2. **`set -o pipefail` + `grep -q`** makes results depend on input order: `grep -q` exits
   at the first match and upstream dies of SIGPIPE, returning 141. This produced
   confident, wrong test failures.
3. **`packer validate` cannot catch a dead base OMI** — it only requires `source_omi` to
   be non-empty. Only an API call or a real build can.
4. **`aa-status --enabled` tests the kernel LSM**, which is always present. It does not
   contradict `systemctl disable --now apparmor`, which prevents **profile loading**. The
   accurate claim is "no AppArmor profiles are enforced".
5. **`rladmin status` returns `invalid token 'status'`** on an un-bootstrapped node. That
   is expected, not a defect. Use `curl -sk https://localhost:9443/v1/bootstrap`, which
   should report `state: idle`.
6. **Redis's `.deb` uses dpkg-sig's clearsigned-manifest format**, not a debsigs detached
   signature. An attempt to replace `dpkg-sig` with plain `gpg --verify` failed on the
   real package. `dpkg-sig` is the authority; `verify_deb_manifest()` is the fallback and
   handles both formats.
7. **Editing `/etc/ssh/sshd_config` changes nothing.** `40-outscale.conf` (Outscale's own
   drop-in) is read first and wins. It already sets `PermitRootLogin no` and
   `PasswordAuthentication no`, so T-22 is **already satisfied** — a drop-in numbered
   below 40 is only about owning the guarantee.

## Working agreements to keep

- **Never modify anything outside this repository.** Not `claude-code-dev-setup`, not the
  Run repo, not the VM's provisioning. Name what is needed and leave it to the maintainer.
- **Ask before installing tools in the VM.** It is fully managed by `claude-code-dev-setup`.
- **Do not claim something works without running it.** Three build failures in this
  project came from guessing at a format or a package's availability instead of testing.
- **Commit and push only when asked.** Never push from the VM; write the PR body to
  `debug/git/pr-body.md` and let the maintainer run
  `git-pr-merge --branch <branch> "<title>"` on the host, then `Read`
  `debug/git/git-pr-merge.json`.
- **Be concise.** The maintainer has said so explicitly.

## Remaining work, in order

| # | Item | Gate |
|---|---|---|
| 1 | Validate the UFW rule set | host build + 3-node cluster + a database |
| 2 | **PR 8** — `auditd` with a minimal ruleset (T-23); decide and document the update policy (T-24) | build + cluster |
| 3 | **PR 7 residue** — `10-hardening.conf` + `sshd -T` assertion (T-22, now 🟡: ownership, not a fix) | build |
| 4 | **PR 10** — AppArmor: `complain` mode, collect denials, ship an `/etc/apparmor.d/local` profile for `/opt/redislabs` or document why it stays off (T-20) | build + cluster ⚠ high risk |
| 5 | **PR 11** — README corrections (T-38) and ADRs for everything decided since | — |
| 6 | Housekeeping: `T-41` (run the build inside the Net, **postponed by decision**), `R-01` drift guard follow-up, `T-18`/`T-33` cosmetics | — |

`docs/findings.md` is the prioritised view; `docs/TODO.md` the exhaustive register;
`docs/plan/build-remediation.md` the phased plan with per-PR gates.

## Decisions already taken — do not relitigate

- Delivery posture is **customer-facing / SecNumCloud**. Hardening items are release
  blockers, not backlog.
- **Redis Flex works** (Run attaches two `io1` volumes, forces `queue/rotational=0`, runs
  `prepare_flash.sh`). Build correctly prepares nothing. Don't "fix" it.
- **Ubuntu 22.04 is the newest release Redis Enterprise supports** — 24.04 is not on the
  list. Jammy is not a legacy choice. Standard support ends 2027-06-01 while Redis
  Enterprise 8.0 runs to 2028-07-31; Ubuntu Pro ESM covers the gap and `ubuntu-pro-client`
  is retained. Decide before mid-2027.
- **Network exposure is the customer's decision, made in Run.** The Redis port list is
  required and must not shrink; what needs scoping is the source CIDR.
- **`ntp=no` is correct** — a second time daemon beside `systemd-timesyncd` would be
  worse. The build asserts NTP is enabled instead.
- **There was never an Augment/ChatGPT `handover/` folder.** The agent docs were
  reconstructed from code, git history and build logs; see `docs/migration-status.md`.

## Verified reference points

Last good build: **2026-09-18**, `eu-west-2:ami-57a302f4`, Redis Enterprise **8.2.0-78**,
base `ami-88dbc914` (`Ubuntu-22.04-2026-08-10`), `rlcheck` `ALL TESTS PASSED`, `.deb`
signature `GOODSIG … EC5EC593D7D1529F`, ~4 min. **Predates the UFW change.**

Acceptance results on that image: two VMs had distinct SSH host-key fingerprints and
machine-ids (T-11); 2.6 GB used of 29 GB with `/home/outscale/` down to dotfiles (T-31);
`NTP=yes`, `NTPSynchronized=yes` (T-12); `bootstrap_status: idle`.

That image still carries one residue found by the acceptance test itself —
`prepare-and-install-redis-install.sh` was left in `/home/outscale/`. Fixed in the
branch; the next build produces a clean image.
