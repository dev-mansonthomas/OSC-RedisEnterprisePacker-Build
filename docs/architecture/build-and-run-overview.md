# Architecture — end-to-end: BUILD (Redis) → OMI → RUN (customer)

Covers **both** repositories, because neither makes sense alone:

| Repo | Path | Run by | Produces |
|---|---|---|---|
| `OSC-RedisEnterprisePacker-Build` | `~/Projects/OSC-RedisEnterprisePacker-Build` | **Redis** | a tagged Outscale OMI containing Redis Enterprise, installed but unconfigured |
| `OSC-RedisEnterprisePacker-Run` | `~/Projects/OSC-RedisEnterprisePacker-Run` | **the customer** | a live N-node Redis Enterprise cluster launched from that OMI |

Verified against `Build@fe7c72f` and `Run@10d933d` (2025-09-30). Repo-specific detail for Build
stays in `docs/architecture/overview.md`; this document is the joint view.

## 1. Division of labour — and what it settles

```mermaid
flowchart LR
  subgraph R["REDIS  ·  BUILD phase  ·  run once per Redis Enterprise release"]
    direction TB
    B1["osc/osc-setup.sh<br/><i>network scaffolding</i>"]
    B2["build_scripts/build_and_deploy_…sh<br/>+ packer/*.pkr.hcl"]
    B3["image_scripts/<br/>prepare-and-install-redis-install.sh"]
    B4["osc/tear_down_outscale.sh"]
    B2 --- B3
  end

  OMI[["OMI · ami-xxxxxxxx<br/>Redis Enterprise 8.0.2-41<br/>Ubuntu 22.04 · installed, NOT configured"]]

  subgraph C["CUSTOMER  ·  RUN phase  ·  run per environment"]
    direction TB
    C1["osc/osc-setup.sh<br/><i>Net · subnets · <b>security group</b></i>"]
    C2["osc/cluster_instanciate.sh<br/><i>orchestrator, --nodes N</i>"]
    C3["osc/instanciate_image_outscale.sh<br/><i>one VM + Flex volumes</i>"]
    C4["image_scripts/<br/>create-or-join-redis-cluster.sh<br/><i>rladmin create / join</i>"]
    C5["osc/tear_down_outscale.sh"]
    C6["osc/connect_to_my_instance.sh"]
    C1 --> C2 --> C3 --> C4
  end

  B2 ==> OMI ==> C3
  B1 -.-> B2
  R -. "publishes the OMI ID" .-> C

  style R fill:#e8f4ff,stroke:#0b5fa5
  style C fill:#f3f0ff,stroke:#5b3fa5
  style OMI fill:#fff6e0,stroke:#b8860b
```

**This settles the security-group question.** The customer-facing security group — and therefore
the decision of *which CIDRs may reach SSH, the Cluster Manager UI, the REST API and the
database ports* — is created by **`Run/osc/osc-setup.sh`**, at deployment time, by the
customer. It is **not** a Build concern:

- Build's own security group is never used by the build. The Packer Outscale plugin creates
  and destroys its **own temporary security group** for the build VM (confirmed in
  `build_scripts/packer.out`). Build's `osc-setup.sh` is therefore near-dead code — see
  finding **R-01** in `docs/findings.md`.
- `Run/osc/osc-setup.sh` is **byte-identical** to `Build/osc/osc-setup.sh`
  (`diff` → no output), and `tear_down_outscale.sh` differs by a single `sleep 15`. The
  network scaffolding is duplicated wholesale across the two repos.

So "parameterise the source CIDR" is a **Run** task. In Build it should simply be deleted.

## 2. End-to-end sequence

```mermaid
sequenceDiagram
  autonumber
  participant Redis as Redis (build operator)
  participant Pk as Packer
  participant OMI as Outscale OMI
  participant Cust as Customer operator
  participant API as Outscale API
  participant N1 as Node 1 (init)
  participant Nn as Nodes 2..N (parallel)
  participant DNS as Customer DNS zone

  rect rgb(232,244,255)
  Note over Redis,OMI: BUILD — once per Redis Enterprise release
  Redis->>Pk: build_and_deploy_redis_image_with_packer.sh
  Pk->>Pk: version parsed from redislabs-8.0.2-41-jammy-amd64.tar
  Pk->>OMI: OS prep · GPG verify · install.sh · rlcheck → CreateImage
  Pk-->>Redis: manifest.json → OUTSCALE_AMI_ID
  end

  rect rgb(243,240,255)
  Note over Cust,DNS: RUN — per customer environment
  Cust->>API: osc-setup.sh → Net, 3 subnets, SECURITY GROUP
  Cust->>Cust: cluster_instanciate.sh --nodes N
  Cust->>API: instanciate_image_outscale.sh --node-num 1 --subnet 1
  API->>N1: VM from OMI (+2× io1 Flex volumes)
  Note over N1: wait for state=running, then poll SSH (max 600s)
  Cust->>N1: scp + ssh → create-or-join …  mode=init
  N1->>N1: prepare_flash.sh -y · rladmin cluster create (rack_aware)
  Note over Cust: sleep 30
  par nodes 2..N in parallel (round-robin over AZ 1/2/3)
    Cust->>API: instanciate_image_outscale.sh --node-num i
    API->>Nn: VM from OMI
    Cust->>Nn: create-or-join … mode=join master_ip=<node1>
    Nn->>N1: rladmin cluster join (10 retries, 30s apart)
  end
  Cust-->>DNS: prints A + NS records to paste MANUALLY
  Cust->>Cust: browse https://<cluster_dns>:8443
  end
```

Two things to note in the Run flow:

- **DNS is manual.** The script only *prints* the required `A` and `NS` records; the customer
  pastes them into their zone. Redis Enterprise needs each node to be an `NS` for the cluster
  FQDN so that database endpoints (`redis-12000.<cluster>.<domain>`) resolve — that is why
  Build frees UDP 53 (ADR 0007). Until DNS is published, the cluster is only reachable by IP.
- **Node 1 is sequential, nodes 2..N are parallel.** `10d933d` made this change and claims a
  consistent ~5 min regardless of node count, replacing a fixed `sleep` with real SSH polling.

## 3. The shared contract: `_my_env.sh`

Both repos communicate through one git-ignored shell file that every script `source`s and
several scripts **append** to. It is the backbone of the design and its main fragility.

```mermaid
flowchart TB
  T["_my_env.template.sh (tracked)<br/>OWNER · OUTSCALE_REGION · OUTSCALE_SSH_KEY<br/>REDIS_LOGIN · REDIS_PWD · OUTSCALE_CLUSTER_DNS<br/>FLEX_FLAG · FLEX_SIZE_GB · FLEX_IOPS · MACHINE_TYPE"]
  E[("_my_env.sh<br/><b>append-only</b> · git-ignored")]
  T -->|"cp, then edit"| E

  S1["Build: osc-setup.sh"] -->|appends OSC_NET_ID, OSC_SG_ID,<br/>OSC_SUBNET1..3, OSC_AZ1..3| E
  S2["Build: build_and_deploy_…sh"] -->|appends OUTSCALE_AMI_ID| E
  S3["Run: osc-setup.sh"] -->|appends the SAME OSC_* keys| E
  S4["Run: instanciate_image_outscale.sh<br/>(N parallel invocations)"] -->|appends<br/>OUTSCALE_INSTANCE_PUBLIC_IP_&lt;n&gt;| E
  E --> S5["Run: cluster_instanciate.sh<br/>re-sources it 2× to pick up new IPs"]
  E --> S6["Run: connect_to_my_instance.sh"]
  E --> S7["tear_down_outscale.sh (both)"]

  style E fill:#fff6e0,stroke:#b8860b
  style S4 fill:#fff0f0,stroke:#c00
```

| Key | Written by | Read by |
|---|---|---|
| `OWNER`, `OUTSCALE_REGION`, `OUTSCALE_SSH_KEY` | operator | every script |
| `OSC_NET_ID`, `OSC_IGW_ID`, `OSC_RTB_ID`, `OSC_SG_ID`, `OSC_SUBNET1..3`, `OSC_AZ1..3` | `osc-setup.sh` (either repo) | teardown, `instanciate_image_outscale.sh` |
| `OUTSCALE_AMI_ID` | Build's build wrapper | `instanciate_image_outscale.sh` |
| `REDIS_LOGIN`, `REDIS_PWD`, `OUTSCALE_CLUSTER_DNS` | operator (Run only) | `cluster_instanciate.sh` |
| `FLEX_FLAG`, `FLEX_SIZE_GB`, `FLEX_IOPS`, `MACHINE_TYPE` | operator (Run only) | **declared but overridden** — see F-04 |
| `OUTSCALE_INSTANCE_PUBLIC_IP_<n>` | `instanciate_image_outscale.sh`, **concurrently** | `cluster_instanciate.sh`, `connect_to_my_instance.sh` |

The red box is the race: during the parallel phase, N subshells each append to this file while
`cluster_instanciate.sh` re-`source`s it. No locking (finding **F-01**).

## 4. Redis Flex / Auto Tiering — it *is* implemented, in Run

This corrects an earlier reading of the Build repo in isolation. `flash_enabled` in
`create-or-join-redis-cluster.sh` is **not** orphaned:

```mermaid
flowchart LR
  A["instanciate_image_outscale.sh<br/>BlockDeviceMappings:<br/>/dev/sdf + /dev/sdg<br/>io1, FLEX_SIZE_GB, FLEX_IOPS"] --> B
  B["cluster_instanciate.sh · FLE_CMD<br/>udev rule: queue/rotational=0<br/>(Outscale io1 mis-detected as HDD)<br/>udevadm reload + trigger"] --> C
  C["/opt/redislabs/sbin/prepare_flash.sh -y<br/>(RAID0 across the two volumes)"] --> D
  D["rladmin cluster create/join<br/><b>flash_enabled</b>"]
```

The build image deliberately prepares **nothing** for flash — correct, since the volume
geometry is a deployment choice. Commit `34c7939` ("flash not fully enabled") predates
`699110c` "Flex working on outscale" (2025-09-10), so the historical complaint is resolved.
Build's TODO T-17 is amended accordingly.

## 5. Cluster topology produced

```mermaid
flowchart TB
  subgraph NET["Net 10.0.0.0/16 · created by Run/osc-setup.sh"]
    subgraph AZa["subregion a · subnet 10.0.10.0/24"]
      n1["redis-node-1<br/>rack_id = eu-west-2a<br/><b>init</b> · public IP"]
      n4["redis-node-4 …"]
    end
    subgraph AZb["subregion b · subnet 10.0.20.0/24"]
      n2["redis-node-2<br/>rack_id = eu-west-2b<br/>join"]
      n5["redis-node-5 …"]
    end
    subgraph AZc["subregion c · subnet 10.0.30.0/24"]
      n3["redis-node-3<br/>rack_id = eu-west-2c<br/>join"]
    end
    SG["Security group<br/><i>the customer's exposure decision</i>"]
  end
  n2 --> n1
  n3 --> n1
  n4 --> n1
  n5 --> n1
  DNS[("Customer DNS zone<br/>ns1..nsN A records<br/>+ NS delegation")] -.-> n1 & n2 & n3
  style SG fill:#fff6e0,stroke:#b8860b
```

- Nodes are placed **round-robin over the three subregions** (`rr_idx`), and each passes its
  subregion as `rack_id`, with `rack_aware` on the `create`. Redis Enterprise then keeps master
  and replica shards in different racks.
- `--nodes` must be **odd, 3–35** — odd for quorum. Enforced.
- All nodes get **public IPs** (`MapPublicIpOnLaunch`), and `external_addr` is set to the public
  IP. There is no private-subnet or bastion topology on offer (finding **F-10**).

## 6. Properties and consequences

| Property | Consequence |
|---|---|
| **Build produces an unconfigured image** | One OMI serves every customer; nothing customer-specific is baked in. The price: the image alone is not a cluster, and Run must stay in step with it. |
| **`_my_env.sh` is the API between phases** | Zero-friction handoff, but no schema, no validation, no locking, and append-only semantics that shadow earlier runs and orphan cloud resources. |
| **Network scaffolding duplicated byte-for-byte** | Two copies of `osc-setup.sh`/`tear_down_outscale.sh` (one already drifted by a `sleep 15`). A CIDR fix applied in one repo silently misses the other. |
| **`create-or-join-redis-cluster.sh` duplicated byte-for-byte** | Only Run executes it; the Build copy is dead. A security fix must land in Run, and the dead copy should go. |
| **Exposure is a Run/customer decision** | Correct separation. But the shipped default is `0.0.0.0/0` with no parameter, so a customer who does not edit the script inherits full internet exposure (finding **F-02**). |
| **Admin credentials travel by command line and land in logs** | The password is interpolated client-side into an `ssh` heredoc, passed as `argv[3]` to a `sudo` command on the node, echoed by the remote script into `/var/log/redis-enterprise-init.log`, and printed to the operator's terminal at the end. Four exposure points for one secret (findings **F-05**, **F-06**). |
| **Host-key verification disabled everywhere** | `StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null` on every `ssh`/`scp`, over the same channel that carries the admin password. Combined with Build's missing host-key regeneration, there is no authentication of the node at all (finding **F-07**). |
| **DNS is manual** | The cluster is unusable by FQDN until the customer edits their zone, and nothing verifies they did. Acceptable, but it is the one un-automated step in an otherwise end-to-end flow. |
