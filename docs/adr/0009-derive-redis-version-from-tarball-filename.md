# ADR 0009 — Derive the Redis Enterprise version from the tarball filename

- **Status:** Accepted
- **Date:** 2025-08-28 (`4311d68`, "fix typo in file name improve hcl build file")
- **Evidence:** `build_scripts/build_and_deploy_redis_image_with_packer.sh` lines 10-28;
  `locals.redis_tarball_name` and `locals.ami_name` in the HCL

## Context

The Redis Enterprise tarball is not redistributable and is far too large for git (993 MB), so
`redis-software/` is git-ignored and the operator downloads the tarball from
[cloud.redis.io](https://cloud.redis.io) themselves. The build nonetheless needs the exact
version string, in three places: to locate the file, to name the OMI, and to tag it.

Alternatives: a version variable the operator must keep in step with the file they downloaded
(two sources of truth, guaranteed to drift), or reading the version out of the tarball's
contents (requires unpacking 993 MB on the host before the build starts).

## Decision

Treat the **filename as the single source of truth** and parse it:

```sh
FILE=$(ls ../redis-software/redislabs-*.tar | head -n 1)
REDIS_VERSION=$(basename "$FILE" | sed -E 's/^redislabs-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*/\1/')
export PKR_VAR_redis_version="$REDIS_VERSION"
```

The HCL then reconstructs the expected filename from the variable, so the two must agree.

## Consequences

**Positive**

- Drop in a new tarball and the next build picks up the new version — no file to edit. Verified
  in practice: `fe7c72f` ("various fixes for Redis Enterprise 8.x") needed no version edit for
  the 7.22 → 8.0.2 move.
- Version traceability is automatic: `8.0.2-41` lands in the OMI name and in the
  `RedisVersion` tag.
- Reconstructing the filename in the HCL makes a mismatch fail loudly at the file provisioner.

**Negative**

- Relies on Redis's download naming convention `redislabs-<maj>.<min>.<patch>-<build>-jammy-amd64.tar`.
  A rename upstream breaks the build.
- If the regex does not match, `sed` returns the basename **unchanged** and non-empty, so the
  script's `if [ -z "$REDIS_VERSION" ]` guard never fires; the failure surfaces later as a
  confusing missing-file error (TODO T-05).
- `ls … | head -n 1` silently picks the alphabetically first tarball when several are present —
  usually the **older** version, i.e. it fails toward the wrong answer rather than an error
  (TODO T-05).
- The stale `variable "redis_version" { default = "7.22.0-95" }` in the HCL is dead weight and
  actively misleading for anyone running `packer build` directly (TODO T-07).
- No integrity check: the filename is trusted, but the tarball's checksum is never verified
  (TODO T-13).
