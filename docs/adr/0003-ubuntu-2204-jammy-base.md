# ADR 0003 — Base the image on Ubuntu 22.04 LTS (Jammy)

- **Status:** Accepted (revisit before mid-2027 — Ubuntu 22.04 standard support ends 2027-06-01)
- **Date:** 2025-06-12 (`93d43c3`)
- **Evidence:** `source_omi = "ami-054f16b1"` (Ubuntu 22.04 LTS, eu-west-2, 2025.07.07);
  tarball `redislabs-8.0.2-41-jammy-amd64.tar`; `README.md` "Choose the Ubuntu 22.04 version"

## Context

Redis Enterprise Software ships per-distribution tarballs. The choice of guest OS is
constrained by which tarballs Redis publishes and which distributions Outscale offers as a
maintained base OMI. Redis publishes a `jammy` (22.04) build; Outscale maintains an official
Ubuntu 22.04 LTS OMI.

## Decision

Build on Ubuntu 22.04 LTS from Outscale's official OMI, pinned by ID (`ami-054f16b1`), and use
the matching `jammy-amd64` Redis Enterprise tarball.

## Consequences

**Positive**

- Distribution matches the Redis tarball exactly — no compatibility guesswork.
- Outscale-maintained base, so the image inherits their platform integration.
- Ubuntu 22.04 standard support runs to **April 2027**, comfortably inside Redis Enterprise
  8.0's EOL of 2028-07-31.

**Negative**

- `source_omi` is a raw region-specific ID: it only exists in `eu-west-2` and will eventually be
  deregistered by Outscale, breaking the build for a non-obvious reason. **A fix exists** — the
  `outscale-bsu` builder supports `source_omi_filter`, so the base image can be pinned by *name*
  instead (TODO T-10).
- The pinned base snapshot is from 2025-07-07, so every build begins with ~4 months of pending
  updates, absorbed by `apt-get upgrade` — which in turn makes builds non-reproducible.
- **Verified 2026-09-17:** Redis Enterprise Software's
  [supported platforms](https://redis.io/docs/latest/operate/rs/references/supported-platforms/)
  list **Ubuntu 22.04, 20.04, 18.04, 16.04** — **24.04 (Noble) is not supported.** Jammy is
  therefore the *newest* supported option, not a legacy choice, and there is no 24.04 migration to
  plan yet.
- A lifecycle gap remains: Ubuntu 22.04 standard support ends **2027-06-01** while Redis Enterprise
  8.0 runs to **2028-07-31**. Ubuntu Pro ESM covers it (22.04 ESM to **2032-04-21**), and the image
  retains `ubuntu-pro-client`, so ESM stays available. Decide before mid-2027 whether to attach an
  Ubuntu Pro token to the OMI, or whether a `noble` tarball will exist by then.
