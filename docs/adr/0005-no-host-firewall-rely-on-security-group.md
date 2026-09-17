# ADR 0005 — No host firewall in the image; rely on the Outscale security group

- **Status:** Accepted provisionally — **explicitly flagged for reversal**
- **Date:** 2025-09-17 or earlier; `firewall=no` present since the first commit
- **Evidence:** `image_scripts/redis-install-answers.txt` → `firewall=no`;
  `image_scripts/prepare-and-install-redis-install.sh` lines 27-51 (entire UFW block commented
  out); `README.md` §TODO → *"test renable ufw + firewall=yes in the answer file"*

## Context

Redis Enterprise needs an unusually wide port surface: database endpoints `10000-19999`, shard
traffic `20000-29999`, internode `3333-3355` and `36379`, management `8080`/`8443`/`9443`/`3346`,
metrics `8070`/`8071`/`9091`/`9125`, DNS/mDNS on UDP `53`/`5353`, and more
([port configurations](https://redis.io/docs/latest/operate/rs/networking/port-configurations/)).

Getting UFW and the installer's own `firewall=yes` both right, at the same time, while
debugging a first working build on a new cloud, was a fight on two fronts. The Outscale
security group already enforces a rule set at the hypervisor.

## Decision

Ship the image with **no host firewall**: `firewall=no` in the installer answers and the UFW
block commented out rather than deleted. Network filtering is the security group's job alone.

## Evidence that this was never actually tested (added 2026-09-17)

`grep -cE '^\s*ufw '` over every revision of `prepare-and-install-redis-install.sh` returns **0**
for all 8 commits that touched it — the UFW block was committed already commented out. And
`firewall=` has read `no` in every revision of `redis-install-answers.txt` since it was introduced
in `4311d68`; it was **never once** set to `yes`.

So the "fight on two fronts" below is the *reason it was deferred*, not a record of a failed
attempt. Nothing in this repository has ever run with a host firewall. The likeliest cause of any
remembered trouble is the mismatch itself — `firewall=yes` without UFW installed, or UFW enabled
without the answer flag — or confusion with AppArmor (ADR 0006), which *was* a real Outscale-era
problem. **Expected cost of reversal is therefore low; the two changes must move together.**

## Consequences

**Positive**

- Unblocked the first working build; removed a whole class of "is it UFW or is it the SG?"
  debugging.
- One place to change a rule instead of two.
- No risk of UFW locking the operator out of a node mid-POC.

**Negative**

- **No defence in depth.** A security-group misconfiguration is immediately a full exposure,
  with nothing behind it — and the group currently hardcodes `0.0.0.0/0` as the source for every
  externally-reachable port, with no parameter to narrow it (TODO T-21). A host firewall would
  bound the damage even when the perimeter rule is wrong.
- **No east-west containment.** Any compromised host inside the Net reaches every port on
  every node, because the "internal" rules allow `10.0.0.0/8`.
- Likely fails a SecNumCloud / ANSSI hardening review, which expects host-level filtering as
  well as perimeter filtering.

**Reversal is now required, not optional** — the repo's delivery posture was confirmed on
2026-09-16 as **customer-facing / SecNumCloud**, which makes host-level filtering a release
blocker rather than backlog (README TODO, our TODO T-19). The commented UFW block is a
working starting point; it should be re-enabled together with `firewall=yes` and then validated
by `rlcheck` plus a real 3-node cluster.
