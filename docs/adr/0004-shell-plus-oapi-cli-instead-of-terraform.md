# ADR 0004 — Provision with `oapi-cli` + Bash, and pass state through `_my_env.sh`

- **Status:** Accepted, but **the state-file part should be reconsidered**
- **Date:** 2025-06-12 (`93d43c3`, "_my_env.sh generation and use is work in progress")
- **Evidence:** `osc/osc-setup.sh`, `osc/tear_down_outscale.sh`, `_my_env.template.sh`; no
  `.tf` / `.tofu` file anywhere in the tree

## Context

The build needs a Net, internet egress, three subnets and a security group. Options:
Terraform/OpenTofu with an Outscale provider, or plain `oapi-cli` calls in shell.

Context that pushed against IaC: the network is **ephemeral scaffolding for a POC**, not a
long-lived environment; the audience is Solution Architects who read Bash more readily than
HCL state semantics; and per the global security model, credentialed work runs on the host
while the VM stays credential-free — so a remote state backend would have been another moving
part to place.

## Decision

Use `oapi-cli` + Bash for provisioning and teardown. Carry generated resource IDs between
scripts (and into `OSC-RedisEnterprisePacker-Run`) by **appending shell assignments to
`_my_env.sh`**, which every script `source`s.

## Consequences

**Positive**

- One dependency (`oapi-cli` + `jq`), no provider versions, no state backend.
- Every API call is visible in the script; easy to read, easy to hand to a customer's security
  team.
- Outputs are already shell variables, so `-Run` consumes them for free.
- Teardown is explicit and ordered, which matches how Outscale actually enforces dependencies.

**Negative — and this is the design's main weakness**

- **No state reconciliation.** `osc-setup.sh` always creates; `tear_down_outscale.sh` always
  deletes by ID. There is no notion of "already correct".
- **Append-only state silently orphans resources.** A second `osc-setup.sh` run appends a
  second `OSC_*` block; `source` keeps the last one, so the earlier Net, subnets and security
  group become unreachable by teardown and **keep billing**. `_my_env.sh` already contains two
  blocks today. The README's workaround is "remove the generated values by hand". This is
  TODO T-01 and the single highest-value fix in the repo.
- **No partial-failure recovery.** `set -e` aborts mid-run without recording what was created,
  so teardown cannot clean up (TODO T-09).
- `_my_env.sh` has no schema and no validation; a typo surfaces as an empty API parameter.

**If revisited:** either rewrite the state file instead of appending (with a guard that
refuses to run when a Net already exists), or move provisioning to OpenTofu — which the VM can
already `validate` credential-free, with `plan`/`apply` staying host-side.
