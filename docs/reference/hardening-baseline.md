# Hardening baseline, measured on a real image

Measured 2026-09-18 on a VM launched from **`ami-57a302f4`** (Redis Enterprise 8.2.0-78,
base `ami-88dbc914`), **un-bootstrapped** — no cluster, no database.

This replaces inference from documentation. It is the reference PRs 7-10 modify, and it
re-prioritises three of them.

## SSH — T-22 is already satisfied

```
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
x11forwarding no
```

Imposed by two drop-ins already present in the base image:

| File | Sets |
|---|---|
| `/etc/ssh/sshd_config.d/40-outscale.conf` | `PermitRootLogin no`, `PasswordAuthentication no` |
| `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` | `PasswordAuthentication no` |

**So the commented-out `sed` block was not merely ineffective — it was unnecessary.**
Outscale's own drop-in already does the job, which is *also* why editing the main
`sshd_config` changed nothing: `40-outscale.conf` is read first and wins.

**Consequence for PR 7:** it is no longer a behaviour change. Its value is *ownership and
durability* — the guarantee is currently inherited from a base image Outscale can change
without notice. A `10-hardening.conf` (lower number = read first = wins) plus an
`sshd -T` assertion in the build turns an inherited accident into a stated contract.
Real value for a SecNumCloud audit, near-zero risk. **Severity drops from 🟠 to 🟡.**

## Firewall — T-19

`ufw` is **installed** and `Status: inactive`. So nothing needs installing; only
enabling, with a correct rule set.

## AppArmor — T-20, and a correction

`aa-status --enabled` → **enabled**, `apparmor module is loaded.`

That looks like it contradicts `systemctl disable --now apparmor`, and it does not:
`aa-status --enabled` tests whether the **kernel LSM** is available, which it always is.
What the disabled service prevents is **profile loading at boot**. So the accurate
statement is "no AppArmor profiles are enforced", not "AppArmor is disabled" — the
wording in ADR 0006 and TODO T-20 was imprecise.

**Still to measure** (the `head -3` cut it off): how many profiles are loaded and in
which mode. Worth capturing on the next VM:

```sh
sudo aa-status | sed -n '1,12p'
```

## Audit — T-23

`auditctl` **absent**: confirmed, no host audit logging.

## Automatic updates — T-24

`dpkg -l unattended-upgrades` → `un` (unknown/not installed): confirmed purged.

## Listening ports — the reference for PR 9

Measured with `ss -tlnp` on an **un-bootstrapped** node:

| Bind | Ports |
|---|---|
| All interfaces | `3344`, `3354`, `8070`, `8080`, `8443`, `9080`, `9443` |
| IPv4 any | `22`, `53` |
| Loopback only | `8002`, `8004`, `8444`, `9081` |
| IPv6 | `22`, `53`, `8004`, `9081` |

Three things this settles:

1. **`3344` and `3354` really do listen.** The commented UFW block omits the whole
   `3333-3355` internode range, which is the concrete reason enabling it would break a
   cluster — previously an inference from the Redis port table, now observed.
2. **`8080` is genuinely listening** — the cleartext REST API. Confirms Run's F-03 is
   about a live service, not a theoretical rule.
3. **Several ports bind loopback only** (`8002`, `8004`, `8444`, `9081`), so they need
   no firewall rule at all. The security group opens `8002`, `8004` and `9081` to
   `10.0.0.0/8` for nothing.

⚠️ **This list is a SUBSET.** The node carries no cluster and no database. Forming a
cluster adds the internode, proxy and shard ports (`1968`, `3346`, `3355`, `36379`,
`20000-29999`), and creating databases adds `10000-19999`. **Building a UFW rule set
from this measurement alone would break a cluster** — it must be combined with the
[Redis port matrix](https://redis.io/docs/latest/operate/rs/networking/port-configurations/),
and re-measured on a *formed 3-node cluster with a database* before PR 9 is trusted.

## Next measurement worth taking

Re-run `ss -tlnp` and `aa-status` on a node that is part of a formed cluster with one
database. That gives the complete port set PR 9 needs and the AppArmor denial picture
PR 10 needs, and it is a by-product of the cluster validation those PRs require anyway.
