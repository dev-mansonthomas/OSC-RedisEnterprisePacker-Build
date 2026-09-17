# Parked findings — `OSC-RedisEnterprisePacker-Run`

**Status: parked, not actionable in this repo.** Produced while auditing Build, because Build
and Run share files and a state file. Carry this into
`~/Projects/OSC-RedisEnterprisePacker-Run` when work starts there; nothing here should be
fixed from the Build repo.

**Audited:** `Run@10d933d` (2025-09-30), cross-read against `Build@fe7c72f`.
**Context:** Run is executed by **the customer** to launch an N-node cluster from the OMI that
Build publishes, so these findings carry more weight than Build's — they are what the customer
runs. Architecture: `docs/architecture/build-and-run-overview.md`.

**Severity:** 🔴 blocks a customer delivery · 🟠 real bug or real risk · 🟡 robustness · ⚪ hygiene

No test suite, no linter config, no CI in Run either. `shellcheck` exits 1.

---

## Secrets and credentials

| ID | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| **F-06** | 🔴 | **A weak default admin password ships in git.** `REDIS_PWD=redis_adm` in the tracked template; the README documents it as the example (l.124, 141) and prints it in the success banner (l.226). **Verified: the live `_my_env.sh` still holds the template default.** A customer following the README gets a publicly-documented admin password on a Cluster Manager reachable from the internet. | `_my_env.template.sh:7`; `README.md:124,141,226` | Ship `REDIS_PWD=` empty; fail fast with a clear message if unset; require ≥16 chars; suggest `openssl rand -base64 24`. Never print it. |
| **F-05** | 🔴 | **The admin password has four exposure points.** (1) `cluster_instanciate.sh:87` uses an **unquoted** `<<EOF`, so `$RS_password` is expanded client-side into the command stream (`shellcheck SC2087`); (2) it lands as `argv[3]` of a `sudo` call on the node — visible in `ps aux`/`/proc/*/cmdline` to any local user; (3) `create-or-join-redis-cluster.sh:28-34` echoes every parameter *including the password* into `/var/log/redis-enterprise-init.log` in cleartext; (4) `cluster_instanciate.sh:182` prints it to the terminal. | `cluster_instanciate.sh:46,87-92,182`; `create-or-join-redis-cluster.sh:28-34` | Stage the secret in an `0600` file via `scp`, switch to a quoted `<<'EOF'` heredoc, read it from that file on the node. Exclude `RS_password` from the echo loop. `chmod 600` the log. Final banner prints URL + username only. |
| **F-07** | 🔴 | **Host-key verification disabled on every SSH/SCP** (`StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`) — on the same channel that carries the admin password and the cluster bootstrap. An on-path attacker impersonates a node and harvests the credential. **Compounded by Build T-11:** the OMI never regenerates host keys, so trust-on-first-use gives nothing either. | `cluster_instanciate.sh:41`; `instanciate_image_outscale.sh:154,181-182`; `connect_to_my_instance.sh:19` | **Ordering matters: fix Build T-11 first.** Then read each node's host key from the Outscale console output and pin it into a per-run `known_hosts`, instead of disabling the check. |
| **F-08** | ⚪ | A personal domain is the committed default cluster FQDN (`outscale.paquerette.com`). | `_my_env.template.sh:8` | Use a placeholder such as `redis.example.com`. |

## Network exposure — the customer's decision, and it has no knob

| ID | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| **F-02** | 🔴 | **The exposure decision is not expressible, and the default is full internet exposure.** The *port list is correct and required* — clients need database ports `10000-19999`, the UI `8443`, the REST API `9443`/`3346`, discovery `8001`, metrics `8070`, cluster DNS on UDP `53`/`5353`. The defect is that every external rule hardcodes source `0.0.0.0/0`, so a customer who does not hand-edit the script gets their admin plane and every database endpoint on the public internet. For a SecNumCloud deployment the answer is very likely "no public exposure at all". | `osc/osc-setup.sh:132-199` | Add `OPERATOR_CIDR` (SSH + UI + REST) and `CLIENT_CIDR` (database + discovery + DNS) to the template, **defaulting to the Net CIDR `10.0.0.0/16`**. Refuse to run with `0.0.0.0/0` unless `--allow-public`. Document the bastion/VPN/peering pattern as recommended. |
| **F-03** | 🟠 | **The cleartext REST API `8080` is opened and is optional.** Redis serves the REST API on `9443` (TLS) *and* `8080` (cleartext); `9443` is already in the rule set. Cleartext admin traffic fails a SecNumCloud review regardless of source CIDR. | `osc/osc-setup.sh:143` | Remove `8080` from the external loop; confirm nothing in the bootstrap path uses it. |
| **F-17** | 🟡 | "Internal" rules allow `10.0.0.0/8` where the Net is `10.0.0.0/16` — a whole private class A as source. *(Was Build T-26; the file belongs to Run.)* | `osc/osc-setup.sh:184,190` | Use the security group's **own ID** as source — the idiomatic intra-cluster rule, immune to CIDR drift. |
| **F-18** | 🟡 | Three internal Redis Enterprise ports **missing**: `8444` (web proxy ↔ `cnm_http`/`cm`), `3357` (internal communication), `8000` (internal metrics). Cross-checked against the [port matrix](https://redis.io/docs/latest/operate/rs/networking/port-configurations/). *(Was Build T-29.)* | `osc/osc-setup.sh:169-185` | Add them. Likely cause of intermittent UI/metrics oddities. |
| **F-10** | 🟡 | **No private-subnet or bastion topology on offer.** All three subnets are public (`MapPublicIpOnLaunch`), every node gets a public IP, `external_addr` is the public IP. A customer wanting a private cluster must rewrite the scripts. | `osc/osc-setup.sh:110-114`; `instanciate_image_outscale.sh:150` | Offer a `PUBLIC_NODES=false` mode: private subnets, NAT for egress, bastion for admin. |
| **F-19** | 🟡 | Only the **Net** is tagged; subnets, route table, Internet Service and SG carry no `Owner` tag, so cost attribution and orphan hunting are incomplete. *(Was Build T-27.)* | `osc/osc-setup.sh:38-41` | Tag every created resource. |

## Concurrency and shared state

| ID | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| **F-01** | 🔴 | **Race on `_my_env.sh` during the parallel node phase.** Nodes 2..N run as background subshells; each calls `instanciate_image_outscale.sh`, which **appends** `OUTSCALE_INSTANCE_PUBLIC_IP_<n>` (l.220), and each subshell then **re-`source`s that same file** (l.139) while siblings are still writing. No locking. The staggered `sleep "$i"` narrows the window but does not close it; at `--nodes 35` there are 34 concurrent writers. | `cluster_instanciate.sh:125-151`; `instanciate_image_outscale.sh:220` | Have `instanciate_image_outscale.sh` print the IP on stdout and let the parent capture it, or write one file per node (`run/node-$n.env`) aggregated after `wait`. The `tmp_ips_file` pattern already used for the recap is the right model — extend it and drop the `_my_env.sh` round-trip. |
| **F-09** | 🟠 | **A failed node silently degrades the cluster.** `for p in "${pids[@]}"; do wait "$p"; done` ignores exit status, so a node whose `join` failed is just absent from the recap. The script reports success and prints DNS records for a cluster smaller than requested — possibly without quorum. | `cluster_instanciate.sh:154` | Collect `wait` exit codes and fail the run. Verify the node count with `rladmin status` before declaring success. |
| **F-20** | 🟠 | **Append-only state orphans billable resources**, same root cause as Build T-01: re-running `osc-setup.sh` creates a new Net and appends a second `OSC_*` block; `source` keeps the last, so the earlier Net/subnets/SG can never be torn down and keep billing. Also applies to `OUTSCALE_INSTANCE_PUBLIC_IP_<n>` across runs. | `osc/osc-setup.sh:213-227`; `instanciate_image_outscale.sh:220` | Rewrite a sentinel-delimited block in place; refuse to run when a live `OSC_NET_ID` exists unless `--force`. |
| **F-11** | 🟡 | `mktemp` temp file has no `trap` cleanup; an abort leaves it in `/tmp`. | `cluster_instanciate.sh:123,160` | `trap 'rm -f "$tmp_ips_file"' EXIT`. |
| **F-21** | 🟡 | **Teardown reports success even when it failed** and **can loop forever** — same two defects as Build T-02/T-04, since the file is a near-identical copy (Run's differs only by a missing `sleep 15`). | `osc/tear_down_outscale.sh:46-68,99-150` | Cap the wait loop; add a final verification pass and exit non-zero if anything survives. |
| **F-15** | 🟡 | `ReadVmsState` called **without `--profile "$OAPI_PROFILE"`** while neighbouring calls pass it — with a non-default profile the poll queries the wrong account and loops forever. Same class as Build T-03. | `instanciate_image_outscale.sh:162` | Add the flag. Audit every `oapi-cli` call in the repo. |

## Configuration correctness

| ID | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| **F-04** | 🟠 | **User configuration is silently overridden.** The script sources `_my_env.sh` (l.4) then **re-declares** `MACHINE_TYPE`, `FLEX_FLAG`, `FLEX_SIZE_GB`, `VOLUME_TYPE`, `FLEX_IOPS` (l.11-15). The operator's values are discarded. Concretely the template says `FLEX_SIZE_GB=20`, the script forces `40` — **the customer gets double the disk they asked for and is billed for it**, with no warning. | `instanciate_image_outscale.sh:4,11-15` | Use `: "${MACHINE_TYPE:=tinav5.c2r4p3}"` style defaults so `_my_env.sh` wins; echo the effective values. |
| **F-12** | 🟠 | **`set -euo pipefail` is set *after* `source`** in `cluster_instanciate.sh` (l.5-6 in that order), so a broken or missing `_my_env.sh` fails silently. `connect_to_my_instance.sh` has **no** `set -euo pipefail` at all. | `cluster_instanciate.sh:5-6`; `connect_to_my_instance.sh:1` | Move `set` to line 2 in both. |
| **F-13** | 🟠 | **Personal identity hardcoded, ignoring config.** `KeypairName "outscale-tmanson-keypair"` is a literal in the `CreateVms` call; `connect_to_my_instance.sh` hardcodes `~/.ssh/outscale-tmanson-keypair.rsa` — even though `OUTSCALE_SSH_KEY` exists and is used elsewhere in the same repo. A customer with a different keypair gets an unusable VM. | `instanciate_image_outscale.sh:134`; `connect_to_my_instance.sh:19` | Add `OUTSCALE_KEYPAIR_NAME` to the template and use `$OUTSCALE_SSH_KEY` throughout. |
| **F-16** | 🟡 | `NODE_IDX` is used on l.58 but only initialised by the argument parser — unlike `SUBNET_IDX`, pre-set to `""` on l.10. Without `--node-num`, `set -u` aborts with an unbound-variable error instead of the intended usage message. | `instanciate_image_outscale.sh:10,36,58` | Pre-initialise `NODE_IDX=""`. |
| **F-14** | 🟡 | **Fixed `sleep 30` after cluster init** instead of polling `rladmin status`. Under load it is either wasted time or too short. `10d933d` already replaced a fixed sleep with real SSH polling — apply the same treatment. | `cluster_instanciate.sh:118-119` | Poll `rladmin status` until the cluster answers. |

## Structure and hygiene

| ID | Sev | Finding | Recommendation |
|---|---|---|---|
| **F-22** | 🟠 | **`osc-setup.sh` is byte-identical to Build's copy** and `tear_down_outscale.sh` differs only by a `sleep 15` — it has **already drifted**. Every network finding above would otherwise need fixing twice. | Run becomes the **single owner**; Build deletes its copies (Build R-01, verified safe: the build VM runs with `"SubnetId":""` and a Packer-generated SG, outside the Net entirely). |
| **F-23** | 🟠 | **`create-or-join-redis-cluster.sh` is byte-identical to Build's copy**, and only Run executes it. F-05 and the IP-detection bug would need fixing twice. | Run is the owner; Build deletes its copy (Build R-02). |
| **F-24** | 🟠 | **Private-IP detection hardcoded to `10/8`** and broken on a multi-address VM (`internal_ip` becomes multi-line, corrupting `/etc/hosts`). Masked today only because `osc-setup.sh` hardcodes `10.0.0.0/16`. *(Was Build T-16.)* | Match any RFC1918 range; take the first address. |
| **F-26** | 🟡 | **Bring-your-own-network mode works but is undocumented.** The maintainer confirms Run has two intended modes: provision a throwaway network with `osc-setup.sh` **for testing**, or **supply the IDs of resources that already exist** in the customer's account. Mode (b) already works de facto — `instanciate_image_outscale.sh` reads `OSC_SG_ID`, `OSC_SUBNET{1,2,3}` and `OSC_AZ{1,2,3}` from `_my_env.sh` and never checks who created them — but nothing says so, and `osc-setup.sh` is presented as a mandatory step 1. A customer with an existing landing zone will either not realise they can skip it, or will run it and get a second Net. | `README.md`; `instanciate_image_outscale.sh:86-96` | Document both modes explicitly; validate the supplied IDs exist (`ReadSubnets`/`ReadSecurityGroups`) and that the three subnets are in three distinct subregions; make clear that in mode (b) the **customer's** security group must carry the Redis Enterprise port matrix. **This is also where F-02's CIDR question really lands** — in mode (b) the customer already owns the decision; mode (a) is the one shipping `0.0.0.0/0`. |
| **F-25** | 🟡 | **DNS is manual and unverified.** The script only *prints* `A`/`NS` records for the customer to paste into their zone; nothing checks they did. Until then the cluster is reachable only by IP. | Acceptable, but document it as a required step and add an optional `dig` check before declaring success. |
| **R-03** | 🟡 | **`.gitignore` is a copy of Build's** and still ignores `redis-software/*`, `build_scripts/manifest.json`, `build_scripts/packer.out`, `build_scripts/install.log` and a `.pem` — none of which exist in Run. It also ignores **itself**. | Trim to what Run actually produces. |
| **R-04** | ⚪ | Dead code: `pause()` in `instanciate_image_outscale.sh:5-8` has an **active** `read -rp` and is never called — if it ever were, it would deadlock the parallel phase. `safe_unlink_route_table()` in the teardown is defined and never called. | Delete. |
| **R-06** | ⚪ | `shellcheck` exits 1: `SC2087` (unquoted heredoc — this **is** F-05), 2× `SC2086` (unquoted `$SSH_OPTS`; benign as written but fragile), `SC2207`, plus `SC1091` info. | Fix `SC2087` with F-05; convert `SSH_OPTS` to a Bash array. |

---

## Suggested order when Run work starts

1. **F-06 → F-05** — the committed weak default, then the four password leak points. Cheapest, highest severity, and the live `_my_env.sh` is still on `redis_adm`.
2. **F-02 + F-03** — give the customer the exposure knob; drop cleartext `8080`.
3. **F-07** — *only after* Build T-11 lands; pin host keys instead of disabling verification.
4. **F-01 + F-20 + F-09** — remove `_my_env.sh` from the parallel path, stop orphaning Nets, make a failed node fail the run.
5. **F-04, F-12, F-13, F-15, F-16** — configuration correctness; F-04 is currently billing the customer double the Flex disk.
6. **F-22 + F-23** — take ownership of the shared scripts once Build has deleted its copies.
7. CI gate: `shellcheck` on the repo (R-06).

## Cross-repo dependencies

| Run finding | Depends on Build |
|---|---|
| **F-07** (pin host keys) | **T-11** — de-identify the image first, or there is nothing stable to pin. |
| **F-22**, **F-23** (single ownership) | **R-01**, **R-02** — Build must delete its duplicate copies. |
| Flex / `flash_enabled` | **Nothing.** Verified working: Run attaches two `io1` volumes, forces `queue/rotational=0` via udev (Outscale mis-detects `io1` as rotational), runs `prepare_flash.sh -y`, then `rladmin` gets `flash_enabled`. Build correctly prepares nothing. |
