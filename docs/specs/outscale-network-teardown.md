# Spec — Outscale network teardown

**Implementation:** `osc/tear_down_outscale.sh` (152 lines)
**Verified against code:** HEAD `fe7c72f`
**Tests:** none exist.

## Purpose

Destroy everything `osc-setup.sh` created, plus any VM still running in the Net, so a finished
POC leaves no billable resource behind.

## Invocation

```sh
cd osc/ && ./tear_down_outscale.sh   # no arguments
```

## Inputs

All read from `../_my_env.sh`, all **mandatory** and asserted with `: "${VAR:?message}"`:
`OSC_NET_ID`, `OSC_RTB_ID`, `OSC_SG_ID`, `OSC_IGW_ID`, `OSC_SUBNET1`, `OSC_SUBNET2`,
`OSC_SUBNET3`. `OAPI_PROFILE` defaults to `default` and may be overridden from the environment.

Missing any of the seven ⇒ a named error and exit before the first API call. ✅

## Outputs

**stdout:** a header echoing the seven IDs, then `[n/7]` progress lines, then
`Teardown terminé.`. No file is written — `_my_env.sh` is **not** cleaned up, so it keeps
pointing at deleted resources.

## Sequence

| Step | Action | On failure |
|---|---|---|
| 1/7 | `ReadVms` filtered by `NetIds` → `DeleteVms` → `wait_vms_terminated` → `sleep 15` | hard fail on `ReadVms`/`DeleteVms` |
| 2/7 | `DeleteRoute 0.0.0.0/0` | `\|\| true` |
| 3/7 | `ReadRouteTables` → `UnlinkRouteTable` per `LinkRouteTableId` | **hard fail** (`jq -e` on `.Errors`) |
| 4/7 | `DeleteRouteTable` | `\|\| true` |
| 5/7 | `DeleteSecurityGroup` | `\|\| true` |
| 6/7 | `UnlinkInternetService` → `DeleteInternetService` | `\|\| true` |
| 7/7 | `DeleteSubnet` ×3 → `DeleteNet` | `\|\| true` |

Order matters: Outscale refuses to delete a referenced resource, so links are removed before
their targets.

## Behaviour notes

- `wait_vms_terminated()` polls `ReadVmsState` every 5 s and stops when either no `VmStates`
  are returned or none is in a state other than `terminated`.
- `json_arr()` turns a Bash list into a JSON array via `jq -R . | jq -s .`.
- `safe_unlink_route_table()` is **defined but never called** (dead code, lines 76-82) — step
  3/7 unlinks by `LinkRouteTableId` instead.
- The deliberate `|| true` on most deletes makes a partially-created environment tearable down.

## Edge cases

| Case | Current behaviour | Assessment |
|---|---|---|
| A VM never reaches `terminated` | `while :;` has a `tries` counter but **no ceiling** ⇒ **infinite loop** | 🔴 T-02 |
| Resource already deleted | `\|\| true` swallows it | ✅ idempotent |
| `_my_env.sh` holds several `OSC_*` blocks | Only the **last** block is in effect; earlier Nets are never touched and keep billing | 🔴 T-01 |
| `OAPI_PROFILE` overridden | Steps 3/7's `ReadRouteTables` (line 109) and `UnlinkRouteTable` (line 117) omit `--profile`, so they hit the `default` profile while every other call uses the override ⇒ teardown targets two different accounts | 🟠 T-03 |
| A VM outside the Net but using `OSC_SG_ID` | `DeleteSecurityGroup` fails, is swallowed by `\|\| true`, then `DeleteNet` fails ⇒ silent partial teardown, exit code still `0` | 🟠 T-04 |
| `DeleteNet` fails for any reason | Reported on stdout, swallowed, exit `0` — the script claims success | 🟠 T-04 |
| `ReadVms` returns no `Vms` key | `jq -r '.Vms[]?.VmId'` yields empty, `VM_IDS` is empty, step skipped | ✅ |

## Acceptance criteria

1. With a valid `_my_env.sh`, exit code is `0` and afterwards `ReadNets` on `OSC_NET_ID`
   returns no Net.
2. Running it twice in a row succeeds both times (second run is a no-op).
3. VMs inside the Net are terminated before subnet deletion is attempted.
4. Absence of any required `OSC_*` variable produces a named error and no API call.
5. **(Not currently met)** `wait_vms_terminated` gives up after a bounded number of attempts
   and exits non-zero.
6. **(Not currently met)** Exit code is non-zero if any resource survives; the script verifies
   deletion rather than trusting `|| true`.
7. **(Not currently met)** `_my_env.sh` is cleaned of the torn-down `OSC_*` block, or the
   script refuses to run when several blocks are present.
8. **(Not currently met)** Every `oapi-cli` call passes `--profile "$OAPI_PROFILE"`.
