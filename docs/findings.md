# Findings — what to improve in **BUILD**

Scope: **this repository only.** Run-phase findings are parked in
`docs/handover-run-findings.md` and must not be fixed from here. End-to-end context:
`docs/architecture/build-and-run-overview.md`.

Audited `Build@fe7c72f` against the code, `git log`, the real build log
(`build_scripts/packer.out`, 2025-11-25 → `eu-west-2:ami-06426132`), `shellcheck`, and Redis's
published [port matrix](https://redis.io/docs/latest/operate/rs/networking/port-configurations/).

**Delivery posture (confirmed 2026-09-16): customer-facing / SecNumCloud.** Redis runs this
build to publish the OMI, and Outscale customers audit and reproduce it — so the hardening
items are **release blockers, not backlog**.

**Severity:** 🔴 blocks a customer delivery · 🟠 real bug or real risk · 🟡 robustness · ⚪ hygiene

IDs are the `T-nn` from `docs/TODO.md`, which stays the exhaustive register; this file is the
prioritised view. No test suite, no linter config and no CI exists.

---

## 1. De-duplicate the shared scripts

Revised 2026-09-17 after discussion. **R-01 is withdrawn as a deletion**; the duplication stands.

### Ownership model (clarified by the maintainer)

| | Who runs it | Network |
|---|---|---|
| **Build** | **Outscale only** — internal, to produce and publish the OMI | `osc-setup.sh` is operator tooling for the build account |
| **Run** | **the customer** | two modes: (a) use the project's `osc-setup.sh` to provision a throwaway network **for testing**, or (b) supply the IDs of network resources that **already exist** in their account |

Consequence: the **customer-facing** security group is Run's, in both of Run's modes. So the
CIDR/exposure finding (**F-02**) belongs to `docs/handover-run-findings.md` and **does not apply
to Build's copy** — Build's network is an internal build account, not something a customer is
exposed to. *(An earlier revision of this file said the opposite; corrected.)*

Run's mode (b) — bring-your-own network — already works de facto, since
`instanciate_image_outscale.sh` reads `OSC_SG_ID`, `OSC_SUBNET{1,2,3}` and `OSC_AZ{1,2,3}` from
`_my_env.sh` and never checks who created them. It is undocumented, though; recorded as **F-26**
in the Run findings.

| ID | Sev | Finding |
|---|---|---|
| **T-41** | 🟠 | **The build does not run inside the Net that `osc-setup.sh` creates — although it should.** Maintainer intent (2026-09-17): the build needs a VM in a Net, with IPs and internet access. **That is not what happens today.** `packer.out` shows the build VM launched with `"SubnetId":""` and a Packer-generated security group, i.e. in Outscale's non-Net public space, getting a public IP directly. It works, but it is not the intended posture, and it means `osc-setup.sh`'s Net/subnets/SG are provisioned and then ignored. |
| | | **The plugin supports what is needed** — the `outscale-bsu` builder documents `subnet_id` (*"required if you are using a non-default Net"*), `net_id`, `security_group_id`/`security_group_ids`, `subregion_name`, and `associate_public_ip_address` (*"If using a non-default Net, public IP addresses are not provided by default"*). **Action:** wire the HCL to `_my_env.sh` — pass `OSC_SUBNET1` as `subnet_id`, `OSC_AZ1` as `subregion_name`, and either set `associate_public_ip_address = true` or rely on the subnet's `MapPublicIpOnLaunch` (which `osc-setup.sh` already enables). Leave the security group to Packer's temporary one — it is correctly scoped to just SSH for the build, and reusing the customer-shaped `OSC_SG_ID` would be *wider* than the build needs. Keep `ssh_interface = "public_ip"`. This is what makes `osc-setup.sh` load-bearing instead of decorative. |
| **R-01** | 🟠 | **`osc/osc-setup.sh` and `osc/tear_down_outscale.sh` stay in Build** (maintainer decision) — the build legitimately needs its own network. They are, however, **duplicated and already drifting**: `osc-setup.sh` is byte-identical to Run's copy, `tear_down_outscale.sh` differs only by a `sleep 15`. Every network fix must be made twice. |
| | | **Action:** (1) add a `diff` guard to the lint job so the two copies cannot diverge silently, and reconcile the existing `sleep 15` difference; (2) once **T-41** lands, `osc-setup.sh` becomes a real prerequisite of the build — document it as such in `README.md` rather than as an optional step. Note the two repos' copies may legitimately need to diverge later (the build wants a minimal single-subnet network; the customer wants three AZs and the full port matrix) — if so, split them deliberately into `osc/build-net.sh` here and keep the full version in Run, rather than letting them drift by accident. |
| **R-02** | 🟠 | **`image_scripts/create-or-join-redis-cluster.sh` — confirmed for deletion (maintainer, 2026-09-17).** It is not in the built image: the HCL has exactly three `provisioner "file"` blocks (`prepare-and-install-redis-install.sh`, `redis-install-answers.txt`, the tarball), the build log shows exactly three uploads, and `create-or-join` appears **0 times** in `packer.out`, the HCL and the provisioning script. Run `scp`s its own copy at cluster-creation time. **Action:** `git rm image_scripts/create-or-join-redis-cluster.sh`; Run becomes sole owner, so F-05 and F-24 get fixed once. |

## 2. Image security — release blockers

| ID | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| **T-11** | 🔴 | **No image de-identification.** No `cloud-init clean`, no removal of `/etc/ssh/ssh_host_*`, no `/etc/machine-id` reset — **confirmed by zero matches in `packer.out`**. Every VM launched from the OMI therefore shares the same SSH host keys and machine-id: host-key reuse enables impersonation between nodes and defeats any host-key pinning. **This also blocks Run's F-07** (Run disables host-key checking because there is nothing stable to pin). | `prepare-and-install-redis-install.sh` — missing final step | Add as the **last** provisioner step: `cloud-init clean --logs`, `rm -f /etc/ssh/ssh_host_*`, `truncate -s 0 /etc/machine-id`, `rm -f /var/lib/dbus/machine-id`. Verify on two VMs from the same OMI that `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` differs. |
| **T-13** | 🔴 | **Circular GPG trust.** The signing key is imported from `rlec_install_utils_tmpdir/GPG-KEY-redislabs-packages` *inside the tarball*, then used to verify the `.deb` from that same tarball — an attacker who replaces the tarball supplies both. No checksum on the tarball either. | `prepare-and-install-redis-install.sh:101-111` | Pin Redis's key fingerprint in the repo (the last build used `EC5EC593D7D1529F`, "Redis Labs Package Signing Key (2020)") and assert it after import. Add `sha256sum -c` against a pinned digest before extraction. |
| **T-19** | 🟠 | **No host firewall** (`firewall=no`; the UFW block committed already commented out). **What git shows, and what it does not:** `grep -cE '^\s*ufw '` returns **0** across all 8 revisions of the script, and `firewall=` has read `no` in every revision since `4311d68`. **The maintainer confirms UFW *was* tested — it was never committed because it was never got working.** Absence from git is therefore evidence about the *record*, not about the *effort*: what we lack is any trace of the configuration that failed, so the attempt has to start from scratch rather than from a known-bad state. **Expected cost: unknown, not low** — an earlier revision of this file wrongly inferred "likely to just work". | `redis-install-answers.txt:4`; `prepare-and-install-redis-install.sh:27-51` | Move UFW and `firewall=yes` **together** — a mismatch in either direction is the most likely failure mode and worth ruling out first. **Probable root cause found.** Diffed the commented UFW allow-list against the port set `osc-setup.sh` opens internally (the configuration that demonstrably works): the UFW block is missing **`1968`, `3333-3355`, `8002`, `8004`, `8006`, `8071`, `9082`, `9091`, `9125`, `36379`** — i.e. **every internode, proxy, envoy and internal-metrics port**. It allows only SSH, `8001`, `8070`, `8443`, `8444`, `9080`, `9081`, `9443`, `10000-19999`, `20000-29999` and UDP `53`/`5353`. With `ufw default deny incoming` followed by `ufw --force enable`, **a cluster cannot form** — nodes cannot gossip, the proxy cannot reach shards, and envoy health checks fail. That is almost certainly what was hit. The fix is to derive the UFW allow-list from the same port table as the security group, not to hand-maintain a second list. Validate with `rlcheck` **and** a real 3-node cluster. |

| **T-22** | 🟠 | **SSH hardening is inert**, and the comment blames the wrong thing (*"somehow, this wasn't working on Outscale"*). **Root cause identified:** Ubuntu cloud images ship `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`, processed via `Include` before the main file, so its directives win over `sed` edits to `sshd_config`. | `prepare-and-install-redis-install.sh:80-89` | Write `/etc/ssh/sshd_config.d/10-hardening.conf` instead (lower number = higher priority): `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`. Assert with `sshd -T`. |
| **T-20** | 🟠 | **AppArmor disabled** (`systemctl disable --now apparmor`, confirmed executing in `packer.out`). **Correction (2026-09-17): this was NOT present from the first commit** — earlier note was wrong. Git bisect of the file shows it absent through `4311d68` (2025-08-28) and present from **`df62416` (2025-09-09, "working, documentation still to be done")** — i.e. it appeared exactly during the Outscale bring-up, the same day as `eb402cd` "Outscale working". That correlation makes it **likely a real fix for a real problem**, unlike T-19. | `prepare-and-install-redis-install.sh:93` | Don't just delete it. Build one image with AppArmor in `complain` mode, run `rlcheck` + a 3-node cluster from Run, then read `dmesg \| grep apparmor` and `/var/log/audit`. If denials are confined to `/opt/redislabs`, ship an `/etc/apparmor.d/local` profile instead of disabling MAC wholesale. |
| **T-23** | 🟠 | **No audit logging** — `auditd` install commented out as *"consider this later"*. SecNumCloud/ANSSI reviews expect host audit logging. | `prepare-and-install-redis-install.sh:53-56` | Install and enable `auditd`; add a minimal ruleset for `/opt/redislabs` and privilege escalation. |
| **T-24** | 🟠 | **Automatic security updates removed** (`apt-get remove --purge unattended-upgrades`), so a long-lived node never patches itself. Defensible for a golden image — *if* re-baking is a documented, scheduled operation. Currently it is neither. | `prepare-and-install-redis-install.sh:69` | Decide and write it down: either restore `unattended-upgrades` (security pocket only), or document a re-bake cadence tied to Ubuntu/Redis releases. |
| **T-12** | 🟡 | **Time sync is correct in practice but unasserted** — severity lowered from 🟠 after clarifying the semantics. `ntp=no` means *"installer, do not configure NTP yourself"*; it is **not** an assertion that something else is doing it. The installer says so explicitly and hands the responsibility back: *"NOT auto-configuring NTP, please manually synchronize cluster node clocks."* On this image the outcome is fine — Ubuntu 22.04 ships `systemd-timesyncd` enabled, and `packer.out` shows it upgraded and restarted — so `ntp=no` is the **right choice**: letting the installer add a second time daemon alongside `timesyncd` would be worse. The gap is only that nothing verifies it, and **`rlcheck` does not check clocks** (verified: the tests run are `verify_capabilities`, `verify_existing_sockets`, `verify_host_settings`, `verify_owner_and_group`, `verify_port_range` — no time test). | `redis-install-answers.txt:3` | Keep `ntp=no`. Add a one-line build assertion: `timedatectl show -p NTPSynchronized --value` must be `yes`. Document Outscale's NTP source for a Net with no internet egress — the case where this silently breaks. |
| **T-28** | ⚪ | **Verified clean, no action.** `_my_env.sh` is git-ignored and contains **no secrets** (resource IDs only); credentials live in the shell profile and `~/.osc/config.json`. `.gitignore` covers `.env*`, `*.pem`, `_my_env.sh`, `redis-software/*`. Recorded so the next audit need not re-check. | — | — |

## 3. Build correctness

| ID | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| **T-01** | 🟠 | **Append-only state — confirmed as unwanted behaviour (2026-09-17).** The build wrapper appends `OUTSCALE_AMI_ID` on every run, and `osc-setup.sh` appends a whole `OSC_*` block, so `_my_env.sh` accumulates stale values and `source` silently keeps the last. `_my_env.sh` holds two `OSC_*` blocks today — **a leftover from old runs; the Outscale side has since been cleaned, so nothing is orphaned or billing.** The live risk is the remaining one: `OUTSCALE_AMI_ID` is what Run consumes, and a stale entry launches the **wrong image**. | `build_and_deploy_redis_image_with_packer.sh:60`; `osc/osc-setup.sh:213-227` | Rewrite a sentinel-delimited block in place instead of appending — e.g. between `# >>> generated (outscale) >>>` / `# <<< generated (outscale) <<<` markers, rewritten atomically via a temp file + `mv`. Same fix serves Run's F-20. |
| **T-07** | 🟠 | **Stale and personal Packer defaults:** `redis_version = "7.22.0-95"` (tarball is `8.0.2-41`), `region = "eu-west-1"` while `source_omi = ami-054f16b1` exists **only in eu-west-2**, and `keypair_private_file = "/Users/thomas.manson/.ssh/…"`. A direct `packer build` (without the wrapper) fails or builds the wrong thing. | `packer/…pkr.hcl:12-38` | Remove the defaults and mark the variables required, or align them with reality. A personal absolute path must not ship. |
| **T-05** | 🟠 | **Tarball selection and version parsing fail toward the wrong answer** — `ls … \| head -n 1` silently picks the alphabetically first tarball (usually the **older** version) when several are present, and a filename that does not match the regex leaves `sed` returning the basename *unchanged and non-empty*, so the `-z` guard never fires. **Now scoped as a feature** (see §7). | `build_and_deploy_redis_image_with_packer.sh:10-23` | Short term: fail when more than one tarball matches, and validate `REDIS_VERSION` against `^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$`. Proper fix: §7 below. |
| **T-10** | ✅ | **Resolved 2026-09-17 — and it was not latent, it had already fired.** `ReadImages` on the pinned `ami-054f16b1` returned `"Images":[]`: Outscale had deregistered it, so the next build would have failed *after* uploading the tarball. Replaced with **`ami-88dbc914`** (`Ubuntu-22.04-2026-08-10`, bsu/x86_64, alias `Outscale`). **Operational fact worth keeping:** Outscale republishes a refreshed Ubuntu 22.04 OMI roughly every **2 months** and prunes old ones after about **10** — the oldest still visible was 2025-10-15, and the previous pin dated from 2025-07-07. So this map needs refreshing a few times a year. | `packer/…pkr.hcl` | Done: `source_omi_by_region` map, the refresh query recorded as a comment beside it, and a **read-only `ReadImages` pre-check in the wrapper** that fails fast with that query before packer runs (skippable via `SKIP_OMI_CHECK=1`). `packer validate` cannot catch this — it only requires `source_omi` to be non-empty. |
| **T-08** | 🟠 | **Scripts must be run from their own directory.** `source "$(dirname "$0")/../_my_env.sh"` is path-independent, but the *write* target and `$HCL_FILE`/`$MANIFEST_FILE`/the tarball glob are CWD-relative — so running from elsewhere reads the right file and writes the wrong one. | `build_and_deploy_redis_image_with_packer.sh:6,8,10` | Derive everything from `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"`. |
| **T-06** | 🟡 | **OMI-ID extraction failures are not propagated.** A missing `manifest.json` only warns and exits `0`; an empty `jq` match appends a blank `OUTSCALE_AMI_ID=`. | `build_and_deploy_redis_image_with_packer.sh:56-63` | Assert the ID matches `^ami-[0-9a-f]+$`; exit non-zero otherwise. |

## 4. Image size and hygiene

| ID | Sev | Finding | Where |
|---|---|---|---|
| **T-31** | 🟡 | **~2 GB of installer payload baked into the OMI** on a 30 GB root: `/home/outscale/redis-enterprise.tar` (993 MB, confirmed uploaded and never deleted), its extracted tree, `/home/outscale/.gnupg`, `/etc/resolv.conf.orig`, and no `apt-get clean`. The `.gnupg` also carries the key material from T-13. | `prepare-and-install-redis-install.sh` — missing cleanup |
| **T-18** | ⚪ | **OMI name still says `-aws-`**: `packer-redis-enterprise-8.0.2-41-ubuntu-22-lts-aws-20251125-1439`. AWS was dropped in `2e95621`. `.gitignore` also still lists `aws/setup-aws-output.txt` and a `.pem`. | `packer/…pkr.hcl:45`; `.gitignore:38,41` |
| **T-33** | ⚪ | `build_scripts/manifest.json` is git-ignored but **required** by the wrapper to extract the OMI ID; losing it loses build history. | `.gitignore:36-37` |
| **T-32** | ⚪ | `.gitignore` **ignores itself** (line 40). Harmless — already tracked — but confusing. | `.gitignore:40` |
| **T-36** | ⚪ | `//todo generate & register keypair` — the keypair must still be created by hand per the README. | `packer/…pkr.hcl:72` |

### Ubuntu version: 22.04 is the newest option, verified

Relevant to T-10 and ADR 0003, checked 2026-09-17 against Redis's
[supported platforms](https://redis.io/docs/latest/operate/rs/references/supported-platforms/):
Redis Enterprise Software lists **Ubuntu 22.04, 20.04, 18.04, 16.04** — **24.04 (Noble) is not
supported.** So Jammy is not a legacy choice, it is the newest supported one, and there is no
24.04 move to plan yet.

There is a lifecycle gap to note, though: Ubuntu 22.04 standard support ends **2027-06-01**,
while Redis Enterprise 8.0 runs to **2028-07-31**. The gap is covered by Ubuntu Pro ESM
(22.04 ESM to **2032-04-21**), and the image keeps `ubuntu-pro-client` (it appears in the
`apt-get upgrade` list, and only `snapd`/`apport`/`unattended-upgrades` are purged) — so ESM
stays available. Decide before mid-2027 whether the OMI attaches an Ubuntu Pro token, or
whether Redis will have published a `noble` tarball by then.

## 5. Tooling and process

| ID | Sev | Finding |
|---|---|---|
| **T-25** | 🟠 | **No tests, no linter config, no CI.** ~20 findings above with nothing to stop them regressing. Minimum viable: `shellcheck` + `packer fmt -check` + `packer validate` (all credential-free), plus a `bats` test for the version-parsing regex and the OMI-ID extraction. |
| **T-37** | ✅ | **Closed 2026-09-17.** `packer` **1.16.0** installed in the VM from the HashiCorp apt repo, and the outscale plugin **v1.6.1** pulled by `packer init` (note: the last real build used v1.5.0). `scripts/lint.sh` now runs `packer fmt -check`, `packer init` and a full `packer validate`. **Still needs persisting** — add `packer` to `scripts/vm-provision.sh` in the `claude-code-dev-setup` repo (an action for the maintainer, outside this repository) or it is gone on the next `./03-vm-up.sh`. |
| **T-38** | 🟡 | **README is wrong on three points:** it calls the script `build_and_deploy_image_with_packer.sh` (actual: `build_and_deploy_redis_image_with_packer.sh`), shows an `outscale` argument (only `-debug` is parsed), and documents the generated variables as `VPC_ID`/`IGW_ID`/`SUBNET1`/`AZ1` (actual: `OSC_NET_ID`/`OSC_IGW_ID`/`OSC_SUBNET1`/`OSC_AZ1`). It also makes `osc-setup.sh` step 1, which R-01 removes. |
| **T-39** | ⚪ | `shellcheck` exits **1**: 2 warnings — `SC2207` (`tear_down_outscale.sh:87`, removed by R-01) and `SC2206` (`args+=($BUILD_OPTS)`, build:49) — plus 5 info. None changes behaviour today. |

## 6. Closed / not Build's problem

| ID | Outcome |
|---|---|
| **T-17** | **Resolved.** Redis Flex works: Run attaches two `io1` volumes, forces `queue/rotational=0` via udev (Outscale mis-detects `io1` as rotational), runs `prepare_flash.sh -y`, and only then does `rladmin` get `flash_enabled`. `34c7939`'s complaint was fixed by `699110c`. Build correctly prepares nothing for flash. |
| **T-21**, **T-40** | **Superseded → Run** (`handover-run-findings.md` F-02, F-03). The customer-facing security group is Run's, and the port list itself is correct and required. In Build the file is deleted by R-01. |
| **T-15**, **T-16** | **Superseded → Run** (F-05, F-24). The executing copy is Run's; Build's is deleted by R-02. |
| **T-26**, **T-27**, **T-29**, **T-30**, **T-34** | **Moved → Run** (F-17, F-19, F-18, and Run's own hardening) — all live in `osc-setup.sh`/`tear_down_outscale.sh`, deleted from Build by R-01. |
| **T-35** | Closed by R-01 (`pause()` lived in `osc-setup.sh`). |

---

## 7. T-05 as a feature — version detection **and** automatic download

Requested 2026-09-17. **Both halves are now solved** — the earlier note that automatic download
was impossible was wrong; the maintainer supplied the base URL and it works anonymously.

### Detection — verified working

Ran `~/Projects/redis-enterprise-multicloud-terraform/scripts/get_latest_redis_version.sh` live
on 2026-09-17:

```
Full version:    8.2.0-78
Version number:  8.2.0
Build number:    78
```

It scrapes `https://redis.io/docs/latest/operate/rs/release-notes/` for the newest
`<maj>.<min>.x releases` link, then that page for the newest `<maj>.<min>.<patch>-<build>`.
Credential-free, so it runs in the VM. The local tarball is **8.0.2-41** — two minor releases
behind (8.0 GA Oct 2025, EOL 2028-07-31; 8.2 GA Jul 2026).

### Download — verified working

`REDIS_DOWNLOAD_BASE_URL=https://s3.amazonaws.com/redis-enterprise-software-downloads`

The path is **`${BASE}/${MAJ.MIN.PATCH}/redislabs-${FULL_VERSION}-jammy-amd64.tar`** — note the
directory uses the version *without* the build number, while the filename keeps it. Verified
with `HEAD` on three versions:

| Version | Directory | `HTTP` | Size |
|---|---|---|---|
| `8.2.0-78` | `8.2.0/` | **200** | 360 161 280 |
| `8.0.2-41` | `8.0.2/` | **200** | 993 064 960 |
| `7.22.0-95` | `7.22.0/` | **200** | 898 928 640 |

`8.0.2-41`'s size matches the local tarball **byte for byte**, confirming this is where it came
from. Two useful facts fall out: the split into `version_number` + `build_number` that the
existing script already performs is exactly what the URL needs, and **8.2.0 is 2.8× smaller**
than 8.0.2 (343 MB vs 947 MB) — a large win on upload time and on T-31.

Paths that do **not** work (checked, all 403): `<base>/<full-version>/`, `<base>/<file>`,
`<base>/redis-enterprise-software/<ver>/`, `<base>/<maj.min>/`. Bucket listing is also denied,
so the exact version must come from the scraper — the two halves are genuinely coupled.

**No checksum or signature is published** alongside the tarball (`.sha256`, `.md5`, `.sig`,
`.asc` all 403). That constrains T-13: the best available integrity story is *record on first
download, pin thereafter* (trust-on-first-use), plus pinning the GPG key fingerprint
out-of-band. Worth asking Redis whether official digests are published somewhere.

### Proposed design

`build_scripts/lib/redis_version.sh` (sourceable) + `build_scripts/fetch_redis_tarball.sh`:

1. **Vendor the scraper**, hardening three real bugs in the original: `local x=$(...)` masks the
   exit status, so the `if [ $? -ne 0 ]` checks on lines 94-105 **never fire**; `set -e` without
   `-o pipefail`; and no `curl` timeout. Add `--max-time 20 --retry 2` and a distinct exit code
   for "page layout changed" so the caller can degrade gracefully.
2. **Resolve + compare** against `redis-software/redislabs-*.tar`.
3. **Download when missing**, to a `.part` file then `mv` (atomic), with `--continue-at -` so an
   interrupted 343 MB–1 GB transfer resumes. Verify `content-length` against the received size.
4. **Record the digest** in `redis-software/SHA256SUMS` on first download and verify against it
   on every subsequent run (feeds T-13).
5. **Modes:** default = warn only, never block a build · `--require-latest` = exit non-zero if
   behind (CI/release) · `--download` = fetch if absent · `--version X.Y.Z-B` = pin explicitly,
   skipping the scraper entirely (the escape hatch for when redis.io changes layout).
6. **Wire into** `build_and_deploy_redis_image_with_packer.sh` as a pre-flight, which also fixes
   T-05's two silent-wrong-answer bugs (multiple tarballs, non-matching filename).

Runs entirely in the VM: no credentials needed for either half.

## Recommended order for BUILD

Revised 2026-09-17 after discussion.

| # | Items | Why this position | Effort |
|---|---|---|---|
| 1 | **R-02**, and **R-01**'s drift check | R-02 is a one-file deletion. R-01 is now a `diff` guard in CI plus a README note, not a deletion — cheap, and it stops every network fix being made twice. | S |
| 2 | **T-11** | The one Build finding another repo is blocked on (Run's F-07), and the clearest audit failure: every customer VM from the OMI shares SSH host keys. | S |
| 3 | **T-13** | Supply-chain integrity of the artefact being shipped: pin the key fingerprint + a tarball digest. Pairs naturally with §7, which already computes the expected filename. | S |
| 4 | **T-19** | Promoted. Git shows UFW was **never** actually tried, so the expected cost is far lower than the code comments imply, and it closes the biggest hardening gap. Move UFW and `firewall=yes` together. | S–M |
| 5 | **§7 + T-05 + T-01** | Version detection and state rewriting — these three touch the same wrapper script, so do them in one pass. | M |
| 6 | **T-37 + T-25** | `packer` into the VM, then the `shellcheck` / `fmt` / `validate` / `diff`-guard CI gate — **before** the remaining hardening, so regressions get caught. | M |
| 7 | **T-22, T-12, T-20, T-23, T-24** | T-22 is a low-risk drop-in file; T-12 is a one-line assertion. T-20 is the genuine experiment — its git correlation with the Outscale bring-up suggests it fixed something real, so treat deleting it as a hypothesis to test, not a cleanup. Each step validated by `rlcheck` **and** a real 3-node cluster from Run. | L |
| 8 | **T-10, T-31, T-18, T-38, T-32, T-33** | `source_omi_filter` for the base image, slim the OMI, fix the README and the cosmetics. | M |

**Resolved since the first pass:** the orphaned Outscale Net is gone (cleaned manually;
T-01 keeps only its wrong-image risk), Ubuntu 22.04 is confirmed as the newest supported
platform (no 24.04 migration to plan), and Redis Flex is confirmed working (T-17).
