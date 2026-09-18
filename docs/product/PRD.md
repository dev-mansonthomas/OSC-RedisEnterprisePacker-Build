# PRD — Redis Enterprise golden image for Outscale (BUILD phase)

**Status:** working tooling; **target is a customer-facing / SecNumCloud delivery**
(confirmed 2026-09-16), and it is **not yet ready for that** — see *Known gaps*
**Last verified against code:** 2026-09-16 (HEAD `fe7c72f`, 2025-11-25)
**Owner:** Thomas Manson (Redis Solution Architect)

## Problem

Outscale customers — French public sector, defence, health and finance buying a sovereign,
**SecNumCloud-qualified** cloud from a Dassault subsidiary — cannot use the Redis Enterprise
images that Redis publishes on the AWS/Azure/GCP marketplaces. Outscale has no Redis
Enterprise marketplace listing. Every prospect therefore has to install Redis Enterprise
Software by hand on Outscale VMs: download the Jammy tarball, tune the OS, run the
interactive installer, then form a cluster — roughly an hour of error-prone work per node,
and a different result every time.

That friction blocks pre-sales (no quick POC) and makes production deployments hard to
support, because no two customer clusters are configured the same way.

## Goal

Produce a **reproducible, versioned Outscale OMI** containing Redis Enterprise Software
installed and OS-tuned, but **not configured** — so a single image serves every customer and
every environment. Launching nodes and forming the cluster is deliberately a separate phase.

## Users

| User | Need |
|---|---|
| **Redis Solution Architect (primary)** | Stand up a 3+ node Redis Enterprise cluster on Outscale in minutes for a customer POC or a benchmark. |
| **Outscale customer / their ops team** | An image and a documented build they can audit, reproduce in their own Outscale account, and re-baked when Redis ships a new version. |
| **Redis / Outscale partnership** | A credible, repeatable deployment story for the sovereign-cloud market; groundwork for an eventual Outscale marketplace listing. |

## Scope

### In scope (this repo)

1. **Outscale network scaffolding** for the build: a Net, an Internet Service, a route table,
   three public subnets across AZ a/b/c, and a security group carrying the complete Redis
   Enterprise port matrix. (`osc/osc-setup.sh`)
2. **Idempotent-by-rebuild image build**: Packer `outscale-bsu` on Ubuntu 22.04 LTS, OS
   preparation and hardening, GPG signature verification of the Redis `.deb`, unattended
   `install.sh`, and `rlcheck` validation. (`packer/`, `image_scripts/`)
3. **Version traceability**: the Redis Enterprise version is derived from the tarball filename
   and carried into the OMI name and its tags (`RedisVersion`, `Project`, `ManagedBy`).
4. **Full teardown** of everything step 1 created, so a POC costs nothing once finished.
   (`osc/tear_down_outscale.sh`)
5. **Handoff**: the resulting `OUTSCALE_AMI_ID` is written to `_my_env.sh`, which
   `OSC-RedisEnterprisePacker-Run` reuses directly.

### Explicitly out of scope

- **Launching VMs and forming the cluster** → `OSC-RedisEnterprisePacker-Run`.
- **Any runtime configuration** baked into the image (cluster name, admin credentials,
  databases, DNS, certificates). By design, so one image fits all customers.
- **AWS / Azure / GCP.** AWS support existed until `2e95621` (2025-09-29) and was removed on
  purpose; the sibling repo `RedisEnterprisePacker` keeps the multi-cloud variant.
- **Terraform / OpenTofu.** Deliberately plain `oapi-cli` + Bash — see `docs/adr/0004`.
- **Redis Enterprise licensing.** The customer supplies their own tarball and licence.

## Non-functional requirements

| Requirement | Why it matters here | Current state |
|---|---|---|
| **Security** | SecNumCloud customers audit what they run, and the image is the attack surface. Posture confirmed **customer-facing**, so these are **release blockers, not backlog**. | 🔴 **Not met.** Host firewall and AppArmor disabled, no `auditd`, SSH hardening inert, no image de-identification (shared SSH host keys), admin password logged in cleartext, and no way to narrow the security group's source CIDR. See `docs/TODO.md` §Security. |
| **Performance** | Redis Enterprise is bought for latency. | ✅ Largely met: swap permanently disabled, Redis's own `systune` applied, ephemeral port range widened to `30000-65535`, `rlcheck` passes. |
| **Reproducibility** | Same inputs must give the same image. | ⚠️ Partial: `force_deregister` makes rebuilds safe and the version is pinned by filename, but the base OMI is a hardcoded ID, `apt-get upgrade` is unpinned, and there is no checksum on the tarball. |
| **Auditability** | Customers need to see exactly what was done to the image. | ⚠️ Partial: `PACKER_LOG` output is kept (`packer.out`) and the OMI is tagged, but no SBOM and no signed provenance. |
| **Cost control** | POCs must leave nothing behind. | ⚠️ Partial: teardown exists but only removes the *last* provisioned Net (see `docs/TODO.md` T-01). |

## Acceptance criteria (product level)

1. From a clean Outscale account with credentials configured, the three documented commands
   run in order produce a usable OMI and then leave no billable resource behind.
2. The OMI's name and tags state the exact Redis Enterprise version.
3. `rlcheck` reports `ALL TESTS PASSED` during the build. *(Verified 2025-11-25.)*
4. A cluster built from the image by `-Run` reaches `active` on 3 nodes across 3 AZs with
   `rack_aware` enabled. *(Owned by `-Run`; not verifiable from this repo.)*
5. **(Not yet met — and now a blocker, given the confirmed posture)** The image passes a
   SecNumCloud-oriented hardening review: host firewall
   on, MAC enforcement on, audit logging on, no shared host identity, no cleartext admin
   protocol, no secret in any log, and an exposure perimeter the customer sets explicitly.

## Known gaps → next steps

See `docs/TODO.md`. The three that block a customer-facing delivery:

1. Make the security group's source CIDR a parameter defaulting to the Net CIDR, so the customer
   chooses their exposure instead of inheriting `0.0.0.0/0`; drop the cleartext REST API `8080`.
   (The port list itself is correct — clients legitimately need the database ports, UI and API.)
2. Re-enable host hardening: UFW + `firewall=yes`, AppArmor, SSH hardening via an
   `sshd_config.d/` drop-in, and `auditd`.
3. De-identify the image (`cloud-init clean`, drop SSH host keys and `machine-id`) and clean
   up the ~2 GB installer payload.

Auto Tiering / Redis Flex (`flash_enabled` without a flash device) is **deferred by decision on
2026-09-16** and tracked as known-broken in TODO T-17.
