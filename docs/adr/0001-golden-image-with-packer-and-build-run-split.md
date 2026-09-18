# ADR 0001 — Bake a golden image with Packer, and split BUILD from RUN

- **Status:** Accepted
- **Date:** 2025-06-12 (commit `93d43c3`); split completed 2025-09-29 (`2e95621`)
- **Evidence:** `packer/redis_ubuntu_outscale_image.pkr.hcl`; the separate repo
  `OSC-RedisEnterprisePacker-Run`; `README.md` §Usage step 3

## Context

Outscale has no Redis Enterprise marketplace image. Installing Redis Enterprise by hand on
each node takes ~1 hour, is interactive, and produces a slightly different result every time —
unacceptable both for pre-sales POCs and for supportable customer deployments.

Two shapes were possible: configure nodes at boot (Ansible / cloud-init on a stock Ubuntu
image), or bake an image once and launch from it.

## Decision

Bake a **golden OMI** with Packer containing Redis Enterprise installed and the OS tuned, and
keep it **completely unconfigured**. Node launch and cluster formation live in a separate
repository, `OSC-RedisEnterprisePacker-Run`.

The two repos communicate through a single file, `_my_env.sh`, which this repo appends
`OUTSCALE_AMI_ID` to.

## Consequences

**Positive**

- Node boot is fast: no 993 MB download, no apt work, no installer at launch time.
- The image is a single auditable artefact, tagged with its exact Redis Enterprise version —
  which is what a SecNumCloud customer wants to review.
- One image serves every customer and every environment, because nothing customer-specific is
  baked in.
- `rlcheck` runs at build time, so a broken image fails the build rather than a POC.

**Negative**

- Two repos must be kept in step; a change to the image's assumptions can break `-Run`
  silently. `image_scripts/create-or-join-redis-cluster.sh` is already duplicated across both.
- A new Redis Enterprise version means a full rebuild (~5 minutes of build plus a 993 MB
  upload), not a package bump.
- The image needs de-identification that the build does not yet do — every VM launched from the
  OMI currently shares its SSH host keys and `machine-id` (TODO T-11).
- The interface is a shell file with no schema, which turned out to be the design's weakest
  point (see ADR 0004).
