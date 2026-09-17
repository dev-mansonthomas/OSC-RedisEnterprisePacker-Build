# ADR 0007 — Disable the systemd-resolved stub listener to free UDP 53

- **Status:** Accepted — required, not optional
- **Date:** re-added 2025-07-04 (`984b4c0`, "readd resolved-restart to prepare-redis-install.sh")
- **Evidence:** `image_scripts/prepare-and-install-redis-install.sh` lines 73-77

## Context

Redis Enterprise runs its own DNS/mDNS responder on **UDP 53 and 5353** to resolve cluster and
database names (`<db>.<cluster-name>`), which is how clients and nodes find endpoints. Ubuntu's
`systemd-resolved` binds a stub listener on `127.0.0.53:53` by default and takes the port, so
Redis Enterprise's responder cannot start.

Redis's documentation covers this case explicitly under *OS conflicts with port 53*
([port configurations](https://redis.io/docs/latest/operate/rs/networking/port-configurations/)).

The commit history shows this was removed at some point and had to be **put back** — the image
does not work without it.

## Decision

```sh
sed -i '$a DNSStubListener=no' /etc/systemd/resolved.conf
mv /etc/resolv.conf /etc/resolv.conf.orig
ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
service systemd-resolved restart
```

Turn off the stub listener, and repoint `/etc/resolv.conf` at resolved's real upstream file
(`/run/systemd/resolve/resolv.conf`) rather than the now-dead `127.0.0.53` stub.

Keep `systemd-resolved` itself installed — only the stub listener goes. This also preserves
`systemd-timesyncd`, which is what actually keeps node clocks in sync given `ntp=no`
(see ADR 0008).

## Consequences

**Positive**

- UDP 53 is free, so Redis Enterprise's DNS responder starts and cluster/database name
  resolution works.
- Host DNS resolution keeps working through resolved's upstream servers.
- `/etc/resolv.conf.orig` is left as a record of the original file.

**Negative**

- Loses resolved's local DNS caching on the stub address; every lookup goes upstream.
- The three steps are **not idempotent** — re-running appends `DNSStubListener=no` again and
  `mv /etc/resolv.conf` fails. Harmless under Packer (fresh VM per build), but it means the
  script cannot be used to converge an existing node.
- `sed '$a …'` appends blindly to the end of the file rather than editing a `[Resolve]` key,
  which works only because the file's last section is `[Resolve]`. A future Ubuntu change to
  `resolved.conf`'s layout would break it silently.
- The responder then needs UDP 53/5353 reachable, which is legitimate — clients resolve
  database names through it. But the security group currently sources those rules from
  `0.0.0.0/0`, which adds a DNS reflection/amplification vector and discloses cluster topology.
  That is a source-CIDR problem in the security group, not a problem with this decision (T-21).
