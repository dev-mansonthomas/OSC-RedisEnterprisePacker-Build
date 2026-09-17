# ADR 0002 — Target Outscale only; drop the AWS path from this repo

- **Status:** Accepted
- **Date:** 2025-09-29 (commits `2e95621` "leanup to keep BUILD on Outscale", `3251df7`
  "remove one last aws refe")
- **Evidence:** only `source "outscale-bsu"` in the HCL; `osc/` is the sole cloud directory;
  `.gitignore` still lists `aws/setup-aws-output.txt` and
  `build_scripts/ec2_ubuntu_base_for_redis_enteprise.pem`

## Context

The project started as a multi-cloud effort: `2b5f743` (2025-08-29) had a working AWS build
plus Redis Flex, with Outscale "started, not operational". Maintaining both doubled the
scripts (`aws/` and `osc/`) and the Packer sources, and the two clouds diverge enough —
`Net` vs `VPC`, `Subregion` vs `AZ`, `OMI` vs `AMI`, `oapi-cli` vs `aws` CLI — that shared code
became a mess of conditionals.

The actual business need is **Outscale**: a sovereign, SecNumCloud-qualified cloud with no
Redis Enterprise marketplace listing. AWS already has one, so the AWS path had no customer.

## Decision

Strip AWS out of this repository and target Outscale exclusively. The multi-cloud variant is
preserved in the sibling repo `RedisEnterprisePacker`.

## Consequences

**Positive**

- Roughly half the code removed; no cloud-abstraction conditionals.
- Scripts can use Outscale vocabulary and `oapi-cli` semantics directly.
- Effort concentrates on the only cloud that needs this work.

**Negative**

- Re-adding a cloud means resurrecting the abstraction, or forking.
- Leftovers remain and are mildly confusing: the OMI name still contains `-aws-`
  (`packer-redis-enterprise-8.0.2-41-ubuntu-22-lts-aws-20251125-1439`), and `.gitignore`
  still references AWS paths. Cosmetic, tracked as TODO T-18.
