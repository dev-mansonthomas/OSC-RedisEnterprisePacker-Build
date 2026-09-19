# Next tests — Build + Run

Written 2026-09-19, before a reboot. Survives it; this file is tracked.
Companion to `docs/HANDOVER.md` (context) and `docs/plan/build-remediation.md` (plan).

## State to resume from

| | |
|---|---|
| Branch | `feat/image-security-pr6` — **9 commits, unmerged** |
| `main` | `27bba54` (PR #1, Build remediation PR 1-4) |
| Last OMI built | **`ami-89fe7cac`** (2026-09-19 19:21, Redis Enterprise 8.2.0-78) |
| Network in `_my_env.sh` | `vpc-113139c2` · `subnet-4d411cda` · `sg-0bc7642e` · AZ a/b/c |
| Gates | `./scripts/lint.sh` + `./tests/run.sh` → **245/245**, also green with `_my_env.sh` and the tarball absent |

**Already validated on a real image** (`ami-89fe7cac` and its predecessor): GPG fingerprint
pinning, `.deb` signature, `rlcheck`, UFW active with SSH reachable, NTP asserted, host
keys and machine-id de-identified, ~2 GB payload reclaimed, `bootstrap_status: idle`.

**Not validated:** that a cluster forms with UFW active. Everything below exists for that.

---

## TEST 1 — 3-node cluster with UFW active ⬅ the gate

The only thing blocking the merge. A single node cannot prove gossip, proxy and shard
traffic pass; the recorded port measurement is a bare-node **subset**, and the old rule
set looked adequate for exactly that reason.

```sh
# 1a. Is the network still there? (it gets torn down between sessions)
cd ~/Projects/OSC-RedisEnterprisePacker-Build && source _my_env.sh
oapi-cli --profile default ReadNets --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}" | jq '.Nets|length'
#   0  ->  cd osc/ && ./osc-setup.sh && cd .. && source _my_env.sh

# 1b. Carry the OMI and network into the Run repo
grep -E '^(OUTSCALE_AMI_ID|OSC_)' _my_env.sh
#   -> copy those values into ~/Projects/OSC-RedisEnterprisePacker-Run/_my_env.sh
#      (check REDIS_LOGIN / REDIS_PWD / OUTSCALE_CLUSTER_DNS are set there too)

# 1c. Form the cluster
cd ~/Projects/OSC-RedisEnterprisePacker-Run/osc && ./cluster_instanciate.sh --nodes 3
```

**Pass:** all three nodes join, the script prints the DNS records, and
`https://<cluster_dns>:8443` answers after the zone is updated.

**Fail — a node does not join.** That is a port UFW is blocking. On the failing node:

```sh
sudo journalctl -k | grep -i 'UFW BLOCK' | tail -30    # names the missing port directly
sudo ufw status numbered
sudo ss -tlnp
```

Send the `UFW BLOCK` lines. Then **revert rather than debug in place** — that is what the
plan says for this step. The fix is one line in
`image_scripts/redis-enterprise-firewall.sh` plus a test, then rebuild.

## TEST 2 — capture the measurement that is still missing

Only possible while a cluster is up, and **PR 10 depends on it**. Create a database from
the UI first, so the `10000-19999` endpoints appear.

```sh
ssh -i ~/.ssh/outscale-tmanson-keypair.rsa outscale@<node1> '
  sudo ss -tlnp      # the COMPLETE port set
  sudo aa-status     # FULL output; only the first 3 lines were ever captured
' | tee ~/Projects/OSC-RedisEnterprisePacker-Build/debug/git/cluster-baseline.txt
```

Then append it to `docs/reference/hardening-baseline.md`, replacing the bare-node caveat.

## TEST 3 — run-time CIDR re-scoping, never exercised

The build applies port-scope only. The CIDR path has unit tests but has never run against
a live node. On one cluster node:

```sh
sudo /usr/local/sbin/redis-enterprise-firewall --dry-run \
  --cluster-cidr 10.0.0.0/16 --client-cidr 10.0.0.0/16

# then for real, and confirm the cluster SURVIVES it
sudo /usr/local/sbin/redis-enterprise-firewall \
  --cluster-cidr 10.0.0.0/16 --client-cidr 10.0.0.0/16
sudo ufw status verbose | head -20
sudo /opt/redislabs/bin/rladmin status | head -15     # cluster still healthy?
```

Note SSH is deliberately **not** narrowed here: that needs `--scope-ssh` as well, so a
wrong CIDR cannot lock you out.

## TEST 4 — Run-phase, after Build is merged

Separate repository, separate session. The two worst findings there are more severe than
anything left on Build:

- **F-06** `REDIS_PWD=redis_adm` committed in `_my_env.template.sh`, documented in the
  README, printed in the success banner. The live `_my_env.sh` still held the default.
- **F-05** the admin password reaches the node as `argv[3]`, visible in `ps`, and is
  echoed into `/var/log/redis-enterprise-init.log` in cleartext.

Verify on a live cluster node:

```sh
sudo grep -i password /var/log/redis-enterprise-init.log | head
ps aux | grep -i rladmin
```

Full list: `docs/handover-run-findings.md` (27 items). **T-11 is now fixed, which unblocks
F-07** — host keys can be pinned instead of `StrictHostKeyChecking=no`.

---

## Cleanup still owed

```sh
cd ~/Projects/OSC-RedisEnterprisePacker-Build && source _my_env.sh

# The firewall test VM, if it survived
VM=$(awk '{print $1}' debug/git/fw-vm.txt 2>/dev/null); echo "$VM"
oapi-cli --profile default DeleteVms --VmIds "[\"$VM\"]"

# Anything left in the Net
oapi-cli --profile default ReadVms --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}" \
  | jq -r '.Vms[] | "\(.VmId) \(.State)"'

# Stale OMIs: six builds since 2026-09-18, each with a billed snapshot, and NONE is
# cleaned automatically -- the OMI name carries a timestamp, so force_delete_snapshot
# never matches a previous one. Keep $OUTSCALE_AMI_ID, delete the rest.
oapi-cli --profile default ReadImages --Filters '{"AccountAliases":["self"]}' \
  | jq -r '.Images[] | select(.ImageName|test("packer-redis-enterprise"))
           | "\(.ImageId)  \(.CreationDate)"' | sort -k2
echo "keep: $OUTSCALE_AMI_ID"
# oapi-cli --profile default DeleteImage --ImageId ami-xxxxxxxx

# The Net itself -- ONLY if you are not about to run TEST 1
cd osc/ && ./tear_down_outscale.sh && cd ..
oapi-cli --profile default ReadNets --Filters "{\"NetIds\":[\"$OSC_NET_ID\"]}" | jq '.Nets|length'  # want 0
```

`tear_down_outscale.sh` still has two known defects: it can **loop forever** if a VM
sticks in `stopping` (T-02), and it reports success even on partial failure (T-04) — hence
the verification line.

## Decisions waiting

1. **Split the branch or not.** PR 6 (validated) and PR 7's UFW rule set (unvalidated)
   share `feat/image-security-pr6`. Splitting lets PR 6 merge now on its build gate;
   keeping it means one PR gated on TEST 1.
2. **OMI retention.** Nothing prunes old images or snapshots. Worth adding a retention
   step to the build wrapper, like the build-log rotation. Not yet a finding.
3. **`packer` in the VM.** Installed by hand, absent from `scripts/vm-provision.sh` in
   `claude-code-dev-setup`. Gone on the next VM rebuild; `lint.sh` then needs
   `--no-packer` and loses four of eight checks. Outside this repository.
