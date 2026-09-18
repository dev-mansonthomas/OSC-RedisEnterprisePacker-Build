# Spec — Packer image build

**Implementation:** `build_scripts/build_and_deploy_redis_image_with_packer.sh` (62 lines) +
`packer/redis_ubuntu_outscale_image.pkr.hcl` (140 lines)
**Verified against code:** HEAD `fe7c72f`, and against the real build log
`build_scripts/packer.out` (2025-11-25 → `eu-west-2:ami-06426132`).
**Tests:** none exist beyond Redis's own `rlcheck` running inside the build.

## Purpose

Turn a Redis Enterprise Jammy tarball into a tagged, versioned Outscale OMI, and record the
resulting OMI ID for the Run phase.

## Invocation

```sh
cd build_scripts/ && ./build_and_deploy_redis_image_with_packer.sh          # normal
cd build_scripts/ && ./build_and_deploy_redis_image_with_packer.sh -debug   # packer -debug -on-error=ask
```

`-debug` is the **only** argument recognised; `$1` is compared literally and anything else is
silently ignored. (The README's `… outscale` argument does not exist.)
Must be run from `build_scripts/` — `$HCL_FILE`, `$MANIFEST_FILE` and the tarball glob are
relative paths.

## Inputs

| Source | Name | Required | Used for |
|---|---|---|---|
| `../_my_env.sh` | `OUTSCALE_REGION` | **yes** | `-var region=` |
| `../_my_env.sh` | `OUTSCALE_SSH_KEY` | **yes** | `-var keypair_private_file=` |
| `../redis-software/redislabs-*.tar` | first match, alphabetically | **yes** | version parsing + file upload |
| environment | `OSC_ACCESS_KEY`, `OSC_SECRET_KEY` | **yes** | consumed by the Outscale plugin |
| `.pkr.hcl` default | `keypair_name` = `outscale-tmanson-keypair` | — | `ssh_keypair_name` |
| `.pkr.hcl` default | `source_omi` = `ami-054f16b1` | — | Ubuntu 22.04 base (eu-west-2 only) |
| `.pkr.hcl` default | `build_instance_type` = `tinav5.c2r4p1` | — | 2 vCPU / 4 GB build VM |
| `.pkr.hcl` default | `root_volume_size` = `30` | — | GB, gp2, `delete_on_vm_deletion` |

### Version derivation

```sh
FILE=$(ls ../redis-software/redislabs-*.tar | head -n 1)
REDIS_VERSION=$(basename "$FILE" | sed -E 's/^redislabs-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*/\1/')
```

`redislabs-8.0.2-41-jammy-amd64.tar` → `8.0.2-41`. The value is exported as
`PKR_VAR_redis_version` *and* passed as `-var redis_version=` (belt and braces), and the HCL
recomputes the expected filename as `redislabs-${var.redis_version}-jammy-amd64.tar`. So the
tarball name must match that shape exactly or the file provisioner fails.

## Outputs

- **OMI** named `packer-redis-enterprise-${redis_version}-ubuntu-22-lts-aws-${YYYYMMDD-hhmm}`,
  tagged `Name`, `Project=redis-enterprise`, `RedisVersion`, `ManagedBy=packer`. Same tags on
  the snapshot.
- **`./manifest.json`** — appended by the `manifest` post-processor, with `last_run_uuid`.
- **`./packer.out`** — full `PACKER_LOG=1` trace (≈340 KB per build; overwritten each run).
- **`../_my_env.sh`** — `OUTSCALE_AMI_ID=ami-xxxxxxxx` **appended**.

OMI ID extraction:

```sh
AMI_ID=$(jq -r --arg uuid "$(jq -r '.last_run_uuid' manifest.json)" \
  '.builds[] | select(.packer_run_uuid == $uuid) | .artifact_id' manifest.json | cut -d':' -f2)
```

i.e. `eu-west-2:ami-06426132` → `ami-06426132`.

## Build steps (HCL)

1. `packer init` then `packer validate` — both run unconditionally before the build.
2. `source.outscale-bsu`: launch `source_omi`, 30 GB gp2 root, SSH as `outscale` over the
   public IP, `ssh_timeout = 20m` (tolerates the in-build reboot-ish restarts).
   `force_deregister` + `force_delete_snapshot` let a rebuild reuse the same OMI name.
3. `provisioner "file"` ×3 → `prepare-and-install-redis-install.sh`,
   `redis-install-answers.txt`, and the tarball as `/home/outscale/redis-enterprise.tar`.
4. `provisioner "shell"` with `DEBIAN_FRONTEND=noninteractive`: `chmod +x` then
   `sudo -E /home/outscale/prepare-and-install-redis-install.sh`.
   `DEBIAN_FRONTEND` + `sudo -E` exist specifically to silence debconf's "unable to initialize
   frontend: Dialog" failure — documented in a comment at the bottom of the HCL.
5. `post-processor "manifest"` with `strip_path = true`.

Note the Outscale plugin creates and deletes its **own temporary security group** for the
build VM; `osc-setup.sh`'s security group is not involved.

## Edge cases

| Case | Current behaviour | Assessment |
|---|---|---|
| No tarball in `redis-software/` | Named error, exit 1, before Packer runs | ✅ |
| Several tarballs present | `head -n 1` silently picks the alphabetically first — likely the *older* version | 🟠 T-05 |
| Tarball name not matching the regex | `sed` leaves the basename unchanged, so `REDIS_VERSION` is non-empty and the emptiness check never fires; Packer then fails on a missing file | 🟠 T-05 |
| `packer build` fails | `set -e` aborts; `manifest.json` is unchanged, so no stale OMI ID is appended | ✅ |
| `manifest.json` missing | Warning `manifest.json not found`, exit `0` — build failure not propagated | 🟡 T-06 |
| `packer build` succeeds but the `jq` filter matches nothing | `AMI_ID` is empty; `OUTSCALE_AMI_ID=` is appended blank | 🟡 T-06 |
| Repeated builds | `OUTSCALE_AMI_ID` appended each time; `manifest.json` grows (6 entries today) | 🟠 T-01 |
| `packer build` without the wrapper | Uses stale defaults: `redis_version=7.22.0-95` (no such tarball) and `region=eu-west-1` (where `source_omi` does not exist) | 🟠 T-07 |
| `OUTSCALE_REGION` ≠ `eu-west-2` | `source_omi` does not exist in that region; the plugin errors out | 🟠 T-07 |
| Outscale deregisters `ami-054f16b1` | Build breaks permanently; no lookup-by-name fallback | 🟠 T-10 |

## Acceptance criteria

1. With a valid `_my_env.sh`, credentials, and exactly one correctly named tarball, exit code
   is `0`.
2. `manifest.json` gains one `builds[]` entry whose `packer_run_uuid == last_run_uuid` and
   whose `artifact_id` is `<region>:ami-<hex>`.
3. `_my_env.sh` ends with `OUTSCALE_AMI_ID=ami-<hex>`, matching that artefact.
4. The OMI's `RedisVersion` tag equals the version parsed from the tarball filename.
5. `packer.out` contains `ALL TESTS PASSED` (Redis `rlcheck`) and `Installation complete.`
   *(Verified 2025-11-25.)*
6. `packer validate` passes on the HCL with no `-var` overrides. *(Unverified — `packer` is
   not installed in the VM.)*
7. **(Not currently met)** A non-zero exit when the OMI ID cannot be extracted.
8. **(Not currently met)** `packer build` with no `-var` flags produces the same image as the
   wrapper (defaults not stale).
9. **(Not currently met)** The OMI name does not contain `aws`.
10. **(Not currently met)** The tarball's SHA-256 is verified against a known value before use.
