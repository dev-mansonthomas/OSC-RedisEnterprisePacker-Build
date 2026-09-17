# Architecture — OSC-RedisEnterprisePacker-Build

**Verified against** HEAD `fe7c72f` and the last real build log (`build_scripts/packer.out`,
2025-11-25 → `eu-west-2:ami-06426132`).

## 1. Two-repo split

```mermaid
flowchart LR
  subgraph BUILD["OSC-RedisEnterprisePacker-Build (this repo)"]
    A["osc/osc-setup.sh<br/>Net · IGW · RTB · 3 subnets · SG"]
    B["build_scripts/<br/>build_and_deploy_redis_image_with_packer.sh"]
    C["packer/redis_ubuntu_outscale_image.pkr.hcl<br/>outscale-bsu"]
    D["osc/tear_down_outscale.sh"]
    A --> B --> C
  end

  ENV[("_my_env.sh<br/>append-only shared state<br/>git-ignored")]
  OMI[["OMI<br/>ami-xxxxxxxx<br/>Redis Enterprise 8.0.2-41"]]

  subgraph RUN["OSC-RedisEnterprisePacker-Run (sibling repo)"]
    E["osc/instanciate_image_outscale.sh"]
    F["osc/cluster_instanciate.sh"]
    G["image_scripts/create-or-join-redis-cluster.sh<br/>rladmin cluster create / join"]
    E --> F --> G
  end

  A -. "appends OSC_NET_ID, OSC_SG_ID,<br/>OSC_SUBNET1..3, OSC_AZ1..3" .-> ENV
  B -. "appends OUTSCALE_AMI_ID" .-> ENV
  ENV -. "sourced by" .-> D
  ENV -. "copied / reused by" .-> RUN
  C ==> OMI
  OMI ==> E
  D -. "deletes" .-> A

  style BUILD fill:#e8f4ff,stroke:#0b5fa5
  style RUN fill:#f3f0ff,stroke:#5b3fa5
  style ENV fill:#fff6e0,stroke:#b8860b
```

The interface between the two repos is a **file**, not an API: `_my_env.sh`. That is the
single most important architectural fact — and its weakest point (see §6).

## 2. Build sequence

```mermaid
sequenceDiagram
  autonumber
  participant Op as Operator (host)
  participant Env as _my_env.sh
  participant OAPI as Outscale API (oapi-cli)
  participant Pk as Packer + outscale plugin
  participant VM as Build VM (tinav5.c2r4p1)

  Op->>Env: cp _my_env.template.sh → set OWNER / REGION / SSH key
  Op->>OAPI: osc-setup.sh
  OAPI-->>Env: append OSC_NET_ID, OSC_IGW_ID, OSC_RTB_ID, OSC_SG_ID, OSC_SUBNET1..3, OSC_AZ1..3
  Op->>Pk: build_and_deploy_redis_image_with_packer.sh
  Note over Pk: REDIS_VERSION parsed from<br/>redis-software/redislabs-*.tar
  Pk->>Pk: packer init → packer validate
  Pk->>OAPI: RunVms (source_omi ami-054f16b1, 30 GB gp2)
  Note over Pk,VM: plugin creates its own temporary SG —<br/>the SG from osc-setup.sh is NOT used by the build
  Pk->>VM: SSH as outscale (ssh_timeout 20m)
  Pk->>VM: upload prepare-and-install-redis-install.sh
  Pk->>VM: upload redis-install-answers.txt
  Pk->>VM: upload redislabs-8.0.2-41-jammy-amd64.tar (993 MB) → /home/outscale/redis-enterprise.tar
  Pk->>VM: sudo -E prepare-and-install-redis-install.sh
  VM->>VM: OS prep, GPG verify, install.sh -c answers, rlcheck
  VM-->>Pk: ALL TESTS PASSED · Installation complete
  Pk->>OAPI: stop VM → CreateImage → tag OMI + snapshot → terminate VM
  Pk-->>Op: manifest.json (+ last_run_uuid)
  Op->>Env: append OUTSCALE_AMI_ID=ami-xxxxxxxx (jq on manifest.json)
```

**Note step 9 — and this is a gap, not a design.** The Packer Outscale plugin provisions its *own*
throwaway security group for the build VM, **and the build runs outside the Net entirely**
(`"SubnetId":""` in `packer.out`). `osc-setup.sh`'s security group is consumed by the **Run** phase, not by the
build. The intended posture is for the build to run **inside** the Net that `osc-setup.sh` creates — the
`outscale-bsu` builder supports `subnet_id`, `net_id`, `subregion_name` and
`associate_public_ip_address` — but the HCL never sets them, so the Net, subnets and security
group are provisioned and then ignored. Tracked as **T-41**; PR 5 of
`docs/plan/build-remediation.md` wires it up. Until then, do not assume changes to
`osc-setup.sh`'s security group affect the build — they cannot.

## 3. Inside the image — what `prepare-and-install-redis-install.sh` does

```mermaid
flowchart TD
  S([sudo -E, root, HOME=/home/outscale]) --> U{"/home/ubuntu or<br/>/home/outscale?"}
  U -->|neither| X([exit 1])
  U -->|outscale| A1["apt-get update && upgrade<br/>sleep 5"]
  A1 --> A2["umask 0022 → /root/.profile + ~/.profile"]
  A2 --> A3["install dpkg-sig, vim, iotop, curl,<br/>jq, netcat, dnsutils, iputils-ping"]
  A3 --> A4["swapoff -a<br/>systemctl mask swap.target"]
  A4 --> A5["purge snapd, apport,<br/>unattended-upgrades"]
  A5 --> A6["resolved.conf: DNSStubListener=no<br/>relink /etc/resolv.conf → run/systemd/resolve<br/>restart systemd-resolved"]
  A6 --> A7["systemctl disable --now apparmor"]
  A7 --> A8["tar -xf redis-enterprise.tar<br/>→ /home/outscale/redis-enterprise"]
  A8 --> A9["gpg --import GPG-KEY-redislabs-packages<br/>(from inside the tarball)"]
  A9 --> A10["dpkg-sig --verify redislabs_*.deb"]
  A10 --> A11["sysctl net.ipv4.ip_local_port_range<br/>= 30000 65535"]
  A11 --> A12["install.sh -c redis-install-answers.txt"]
  A12 --> A13[["systune=yes · rlcheck=yes<br/>firewall=no · ntp=no"]]

  style A6 fill:#fff0f0,stroke:#c00
  style A7 fill:#fff0f0,stroke:#c00
  style A9 fill:#fff0f0,stroke:#c00
  style A13 fill:#fff0f0,stroke:#c00
```

Red boxes are the deliberate weakenings — each has an ADR (`0005`–`0008`) and a TODO entry.

### Why the resolved-stub / port-range steps exist

Redis Enterprise runs its own DNS/mDNS responder on **UDP 53 and 5353** for cluster and
database name resolution. Ubuntu's `systemd-resolved` stub listener binds `127.0.0.53:53` and
collides with it — hence `DNSStubListener=no` plus relinking `/etc/resolv.conf` to the real
resolved-managed file. Widening `ip_local_port_range` to `30000-65535` keeps the kernel from
handing out ephemeral ports that Redis Enterprise reserves (database `10000-19999`, shard
`20000-29999`, internode `3333-3355`). Both are documented Redis requirements
([port configurations](https://redis.io/docs/latest/operate/rs/networking/port-configurations/)).

## 4. Network topology created by `osc-setup.sh`

```mermaid
flowchart TB
  IGW(["Internet Service (IGW)"])
  subgraph NET["Net 10.0.0.0/16 — tagged Owner=$OWNER, Name=$OWNER-net"]
    RTB["Route table<br/>0.0.0.0/0 → IGW"]
    SN1["Subnet 10.0.10.0/24<br/>{REGION}a · MapPublicIpOnLaunch"]
    SN2["Subnet 10.0.20.0/24<br/>{REGION}b · MapPublicIpOnLaunch"]
    SN3["Subnet 10.0.30.0/24<br/>{REGION}c · MapPublicIpOnLaunch"]
    SG["Security group $OWNER-sg"]
  end
  IGW --- RTB
  RTB --- SN1 & SN2 & SN3
  SG -.- SN1 & SN2 & SN3
```

Three AZs with rack-awareness in mind (`-Run` passes the subregion as `rack_id`). All subnets
are **public** — nodes get public IPs and Redis Enterprise's `external_addr` is set from them.
There is no NAT gateway and no private subnet tier.

### Security group rules, cross-checked against the Redis port matrix

Source of truth: [Network port configurations](https://redis.io/docs/latest/operate/rs/networking/port-configurations/).

| Port(s) | Proto | SG source | Redis "connection source" | Verdict |
|---|---|---|---|---|
| 22 | tcp | `0.0.0.0/0` | n/a (OS) | 🟠 Required for operator access; source should be a bastion/operator CIDR |
| 8001 | tcp | `0.0.0.0/0` + `10.0.0.0/8` | Internal, External | 🟡 Required by clients; source should be the client CIDR |
| 8070 | tcp | `0.0.0.0/0` | External | 🟡 Required by external monitoring; source should be the monitoring CIDR |
| 8080 | tcp | `0.0.0.0/0` | Internal, External, A-A | 🔴 **Cleartext REST API — optional, `9443` is its TLS twin. Drop it (T-40).** |
| 3346 | tcp | `0.0.0.0/0` + `10.0.0.0/8` | Internal, External, A-A | 🟡 Required (REST / node bootstrap); narrow the source |
| 8443 | tcp | `0.0.0.0/0` + `10.0.0.0/8` | Internal, External | 🟡 Required (admin UI over TLS); source should be an operator CIDR |
| 9443 | tcp | `0.0.0.0/0` + `10.0.0.0/8` | Internal, External, A-A | 🟡 Required (REST over TLS); source should be an operator CIDR |
| 10000-10049, 10051-19999 | tcp | `0.0.0.0/0` + `10.0.0.0/8` | Internal, External, A-A | 🟡 **Required — this is how applications reach a database.** Source should be the client CIDR |
| 53, 5353 | udp | `0.0.0.0/0` + `10.0.0.0/8` | Internal, External | 🟠 Required for cluster/database name resolution; but `0.0.0.0/0` adds a reflection/amplification vector — narrow to the client CIDR |
| 20000-29999 | tcp | `10.0.0.0/8` | Internal | 🟡 Correct role, over-broad CIDR |
| 1968, 3333-3345, 3347-3349, 3350-3354, 3355, 36379 | tcp | `10.0.0.0/8` | Internal | 🟡 Correct role, over-broad CIDR |
| 8002, 8004, 8006, 8071, 9080, 9081, 9082, 9091, 9125, 10050 | tcp | `10.0.0.0/8` | Internal | 🟡 Correct role, over-broad CIDR |
| **8444** | tcp | *absent* | Internal (web proxy ↔ cnm_http/cm) | 🟡 **Missing** |
| **3357** | tcp | *absent* | Internal | 🟡 **Missing** |
| **8000** | tcp | *absent* | Internal metrics | 🟡 **Missing** |

**Reading the verdict column correctly:** every port here is required by Redis Enterprise, and the
ones marked *External* genuinely must be reachable **by clients** — that is how applications use a
database and how an operator reaches the UI and API. The finding is not the port list; it is that
the **source CIDR is hardcoded to `0.0.0.0/0`** with no way for the customer to narrow it. Whether
these VMs face the internet at all is the customer's decision, and for a SecNumCloud deployment it
is very likely *no* (TODO T-21).

Three genuine defects remain: the cleartext REST API `8080` is opened although its TLS twin `9443`
is already present and `8080` is optional (T-40); the "internal" rules allow `10.0.0.0/8` where the
Net is `10.0.0.0/16` (T-26); and `8444`, `3357` and `8000` are missing from the internal rules (T-29).

Remember too that **this security group is Run-phase scaffolding** — the Packer plugin builds with
its own throwaway SG (§2, step 9), so nothing here affects the image. The durable version of this
rule set lives in `OSC-RedisEnterprisePacker-Run`.

## 5. Teardown order

`tear_down_outscale.sh` reverses creation, because Outscale refuses to delete a resource that
is still referenced:

```
VMs in the Net  →  default route  →  route-table links  →  route table
              →  security group  →  Internet Service (unlink, then delete)
              →  subnets  →  Net
```

Every destructive call is suffixed `|| true` so a partially-created environment still tears
down. The two exceptions are the `ReadRouteTables`/`UnlinkRouteTable` calls, which fail hard on
an API error — and which are also the two calls that forget `--profile`.

## 6. Design consequences worth knowing

| Property | Consequence |
|---|---|
| **`_my_env.sh` is append-only shared state** | No locking, no schema, no validation. Re-running a script silently shadows the previous run and orphans its cloud resources. The single biggest fragility in the design (`docs/adr/0004`, TODO T-01). |
| **Runtime config deliberately absent from the image** | One OMI serves every customer; the price is that the image alone is not a working cluster and `-Run` must be kept in step with it. |
| **No IaC state** | Nothing reconciles desired vs actual. `osc-setup.sh` always creates; `tear_down` always deletes by ID. Terraform/OpenTofu was rejected on purpose (`docs/adr/0004`). |
| **Base OMI pinned by raw ID** | `ami-054f16b1` is region-specific (eu-west-2) and will eventually be deregistered by Outscale, breaking the build. There is no data-source lookup by name. |
| **`apt-get upgrade` unpinned** | Every rebuild picks up whatever Ubuntu ships that day. Good for patching, bad for bit-for-bit reproducibility. |
| **`image_scripts/create-or-join-redis-cluster.sh` duplicated** | Byte-identical in both repos; only `-Run` executes it. Two copies will drift. |
