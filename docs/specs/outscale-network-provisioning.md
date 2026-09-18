# Spec — Outscale network provisioning

**Implementation:** `osc/osc-setup.sh` (227 lines)
**Verified against code:** HEAD `fe7c72f`
**Tests:** none exist. Acceptance criteria below are the contract a future test must assert.

## Purpose

Create the Outscale network scaffolding a Redis Enterprise cluster needs: one Net, internet
egress, three public subnets spread over three AZs, and one security group carrying the full
Redis Enterprise port matrix. Record every generated ID in `_my_env.sh`.

## Invocation

```sh
cd osc/ && ./osc-setup.sh          # no arguments accepted or parsed
```

Must be run **from `osc/`** — it writes to the relative path `../_my_env.sh`.

## Inputs

| Source | Name | Required | Default | Used for |
|---|---|---|---|---|
| `../_my_env.sh` | `OWNER` | **yes** | none — unset ⇒ `set -u` abort | Net name `${OWNER}-net`, SG name `${OWNER}-sg`, `Owner`/`Name` tags |
| `../_my_env.sh` | `OUTSCALE_REGION` | no | `eu-west-2` | Subregion names `${REGION}{a,b,c}` |
| hardcoded | `OAPI_PROFILE` | — | `default` | `oapi-cli --profile` |
| `~/.osc/config.json` | access key, secret key, region | **yes** | — | API authentication |

The access key is region-bound on Outscale, so `OUTSCALE_REGION` only selects the subregion
suffixes — it cannot move the build to another region on its own.

## Outputs

**stdout:** a progress line per created resource, then a `===== OUTSCALE Resource Summary =====`
block listing the Net, IGW, route table, SG, subnets and AZs.

**`../_my_env.sh`** — the following block is **appended** (never rewritten):

```sh
# Generated environment variables (OUTSCALE)
OSC_NET_ID=vpc-xxxxxxxx
OSC_IGW_ID=igw-xxxxxxxx
OSC_RTB_ID=rtb-xxxxxxxx
OSC_SG_ID=sg-xxxxxxxx
OSC_SUBNET1=subnet-xxxxxxxx
OSC_SUBNET2=subnet-xxxxxxxx
OSC_SUBNET3=subnet-xxxxxxxx
OSC_AZ1=eu-west-2a
OSC_AZ2=eu-west-2b
OSC_AZ3=eu-west-2c
```

**Cloud side effects**, in order:

1. `CreateNet --IpRange 10.0.0.0/16`
2. `CreateTags` on the Net: `Owner=$OWNER`, `Name=$OWNER-net`
3. `CreateInternetService` + `LinkInternetService`
4. `CreateRouteTable` + `CreateRoute 0.0.0.0/0 → IGW`
5. For `i` in 1..3: `CreateSubnet 10.0.$((i*10)).0/24` in `${REGION}{a,b,c}`,
   `LinkRouteTable`, `UpdateSubnet --MapPublicIpOnLaunch true`
6. `CreateSecurityGroup ${OWNER}-sg`, then the rule set in
   `docs/architecture/overview.md` §4

## Behaviour notes

- Only the **Net** is tagged. Subnets, route table, Internet Service and security group carry
  no `Owner` tag, so account-wide cost attribution by owner is incomplete.
- Resource IDs are read out of the API response with `jq -r`, with no check that the field was
  present. An API error yields the literal string `null` and the script continues.
- `pause()` is a no-op: the `read -rp` was commented out in `a7b309a` to make the script
  non-interactive. The remaining calls only emit a blank line.
- Subnet CIDRs are `10.0.10.0/24`, `10.0.20.0/24`, `10.0.30.0/24` — deliberately spaced by 10
  so more subnets can be slotted in later.

## Edge cases

| Case | Current behaviour | Assessment |
|---|---|---|
| `_my_env.sh` absent | `source` fails, `set -e` aborts before any API call | ✅ safe |
| `OWNER` unset | `set -u` aborts at `NAME="${OWNER}-net"`, before any API call | ✅ safe |
| Script run twice | Creates a **second, complete, independent** Net and appends a second block. Sourcing keeps the last block ⇒ the first Net is unreachable by `tear_down_outscale.sh` and **keeps billing**. | 🔴 T-01 |
| Run from the repo root | `../_my_env.sh` resolves outside the repo; `source "$(dirname $0)/../_my_env.sh"` still works, so the script writes the generated block to the **wrong file** (or fails) while reading the right one | 🟠 T-08 |
| Region has fewer than 3 subregions | `CreateSubnet` errors, `set -e` aborts mid-way, leaving a partial Net with no record in `_my_env.sh` | 🟠 T-09 — no rollback |
| Any single `oapi-cli` call fails | `set -e` aborts; already-created resources are orphaned and **not** recorded, so teardown cannot find them | 🟠 T-09 |
| Subnet CIDR collides with an existing Net | Not possible — each run gets a brand-new Net | ✅ |
| `jq` missing | `NET_ID` becomes empty, `CreateTags` is called with `[""]` and fails | 🟡 no prerequisite check |

## Acceptance criteria

1. Given a valid `_my_env.sh` and working credentials, exit code is `0` and `_my_env.sh` gains
   exactly one `# Generated environment variables (OUTSCALE)` block with all ten `OSC_*` keys
   set to non-empty, non-`null` values.
2. `ReadNets` on `OSC_NET_ID` returns `IpRange == "10.0.0.0/16"` and tags
   `Owner=$OWNER`, `Name=$OWNER-net`.
3. `ReadRouteTables` on `OSC_RTB_ID` shows a `0.0.0.0/0` route to `OSC_IGW_ID` and exactly
   three subnet links.
4. Each of `OSC_SUBNET1..3` is in a distinct subregion, in the order a, b, c, with
   `MapPublicIpOnLaunch == true`.
5. `ReadSecurityGroups` on `OSC_SG_ID` contains every rule in the §4 matrix.
6. **(Not currently met)** A second invocation either refuses to run or reuses the existing
   Net; `_my_env.sh` never holds two conflicting `OSC_NET_ID` values.
7. **(Not currently met)** A failure part-way through either rolls back or writes the IDs
   created so far so teardown can finish the job.
8. **(Not currently met)** The source CIDR for the externally-reachable ports is configurable
   (`OPERATOR_CIDR`, `CLIENT_CIDR`) and **defaults to the Net CIDR rather than `0.0.0.0/0`** — the
   port list itself is correct and must not shrink, since clients need the database ports, the UI
   and the API. The cleartext REST API `8080` is not opened (`9443` covers it). "Internal" rules
   use `10.0.0.0/16`, not `10.0.0.0/8`. `8444`, `3357` and `8000` are present as internal rules.
