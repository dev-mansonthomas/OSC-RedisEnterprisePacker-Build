## Summary

Implements **PRs 1-4** of `docs/plan/build-remediation.md`, plus the agent-doc
baseline the plan came from. Nothing here touches the image contents or the
Outscale network, so the risk is confined to the build wrapper and its tooling.

The repository had **no tests, no linter config and no CI** before this. That is
the main thing that changes.

## Commits

| Commit | What |
|---|---|
| `docs:` | Agent docs reconstructed from code, git history and the real build log — CLAUDE.md, PRD, architecture, per-script specs, 9 ADRs, findings, the 11-PR plan, and the parked Run findings. There was never a handover folder; provenance is in `docs/migration-status.md`. |
| `ci:` | **PR 1** — `scripts/lint.sh` + `tests/` + GitHub Actions, all credential-free. Fixes the two shellcheck warnings (T-39). |
| `chore:` | **PR 2** — deletes the dead `create-or-join-redis-cluster.sh` (R-02), tidies `.gitignore` (T-32, T-33). |
| `feat(build):` | **PR 3** — Redis Enterprise version detection and tarball download (T-05, T-08). |
| `fix(build):` | **PR 4** — in-place `_my_env.sh` blocks, OMI-ID validation, HCL cleanup (T-01, T-06, T-07, T-10, T-18). |
| `docs:` | Sync the plan and entry map with the shipped state. |
| `fix(packer):` | Real `packer validate`, now that packer is in the VM — fixes two defects it surfaced, one shipped by PR 4. |

## Highlights

**Version detection and download now work end to end.** `fetch_redis_tarball.sh`
resolves the latest release from redis.io and fetches it from
`s3.amazonaws.com/redis-enterprise-software-downloads`. The URL structure took
some probing: the directory component drops the build number while the filename
keeps it — `.../8.2.0/redislabs-8.2.0-78-jammy-amd64.tar`. Verified HTTP 200 on
8.2.0-78, 8.0.2-41 and 7.22.0-95; four other plausible paths return 403 and
bucket listing is denied. The local tarball is **8.0.2-41**, two minor releases
behind **8.2.0-78** (which is also 2.8× smaller).

No upstream checksum is published (`.sha256`/`.md5`/`.sig`/`.asc` all 403), so
integrity is trust-on-first-use: the digest is recorded in
`redis-software/SHA256SUMS` and verified on every later run.

**Three bugs fixed in the vendored version scraper** (from
`redis-enterprise-multicloud-terraform`): `local x=$(cmd)` takes `$?` from the
builtin, so the original's failure checks could never fire; `set -e` without
`-o pipefail`; and no curl timeout.

**`_my_env.sh` is no longer append-only.** It is the interface between
`osc-setup.sh`, the build wrapper and the Run repo, and appending meant `source`
silently kept the last of several assignments — a stale `OUTSCALE_AMI_ID`
launches the wrong image. Writers now own sentinel-delimited blocks rewritten
via temp file + `mv`. The repo's own `_my_env.sh` carried two `OSC_*` blocks and
has been migrated, keeping the values `source` already resolved to.

**Two silent-wrong-answer bugs closed.** `ls | head -1` picked the
alphabetically first tarball (usually the *older* version); and a filename not
matching the version regex left `sed` returning the basename unchanged and
non-empty, so the emptiness guard never fired.

## Verification

```
./scripts/lint.sh   →  passed   (shellcheck · packer fmt/init/validate · drift · secrets)
./tests/run.sh      →  66/66    ALL TESTS PASSED
```

`packer` **1.16.0** was installed in the VM during this work (outscale plugin
**v1.6.1**; the last real build used v1.5.0), so the template is now genuinely
validated rather than skipped. That immediately paid for itself — see below.

Tests cover version parsing, URL construction, numeric ordering, digest
record/verify/mismatch, multiple-tarball and unparseable-name rejection,
in-place block rewriting and idempotency, `_my_env.sh` remaining sourceable, and
the region→OMI map pinned against the real HCL.

### Two defects the real `packer validate` caught

Worth calling out, because one of them was introduced by PR 4 in this same
branch and would have shipped:

1. **The `redis_version` validation block was rejected by packer itself** —
   error messages must start with an uppercase letter, and mine began with the
   lowercase variable name. `packer init` failed outright, so the guard PR 4
   added would never have run.
2. **The three file provisioners used CWD-relative sources**, so packer only
   worked when invoked from `build_scripts/`. They now use `${path.root}`, which
   makes validate and build CWD-independent — the HCL half of T-08.

`lint.sh` now also asserts *negatively* that the `redis_version` guard really
rejects a malformed value, so it cannot silently become decorative again.

⚠️ **`packer` will vanish on the next VM rebuild.** It was installed by hand;
persisting it means adding `packer` to `scripts/vm-provision.sh` in the
`claude-code-dev-setup` repo — outside this repository, so that one is yours.

## What this does NOT do

**A host build is still owed.** PR 4's gate is one successful host-run Packer
build confirming these changes are functionally neutral. That cannot run in the
VM (no credentials, no packer), so please run it before PR 6.

Also deliberately out of scope:
- **T-41 / PR 5 (run the build inside the Net) — postponed by decision.** The
  build currently launches with `"SubnetId":""`, outside the Net that
  `osc-setup.sh` creates. Rewiring it is the one change that could break the
  build for an unrelated reason, so it waits for a green baseline. Meanwhile,
  changes to `osc-setup.sh`'s security group **cannot** affect the build.
- Image hardening (PRs 6-10): GPG fingerprint pinning, de-identification, UFW,
  AppArmor, `auditd`. Each needs a host build and a real 3-node cluster.
- All 27 Run-phase findings, parked in `docs/handover-run-findings.md`.

## Notes for review

- `scripts/shared-drift.baseline` records the deliberate divergence between this
  repo's `osc-setup.sh` and the Run copy. CI fails on *new* drift only.
- `osc-setup.sh`'s security group is unchanged. Its `0.0.0.0/0` rules are a Run
  concern (the customer's exposure decision), tracked as F-02 in the parked
  findings.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
