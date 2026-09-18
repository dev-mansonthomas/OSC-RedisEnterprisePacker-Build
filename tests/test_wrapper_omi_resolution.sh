#!/usr/bin/env bash
# Integration test for the build wrapper's base-OMI resolution.
#
# This exists because a grep-based test did NOT catch the resolution block being
# deleted by an unrelated edit: the assertions were removed in the same edit and the
# suite stayed green. So this RUNS the wrapper against a stub oapi-cli and a stub
# packer, and asserts on its behaviour. Deleting the block now fails the suite.
set -uo pipefail
source "$(dirname "$0")/assert.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

STUBS="$(mktemp -d)"; trap 'rm -rf "$STUBS"' EXIT

# --- stub oapi-cli: returns the fixture for a broad query, one image for an id query
cat > "$STUBS/oapi-cli" <<STUB
#!/usr/bin/env bash
# An ImageIds query answers for that id; ami-dead0000 is the deregistered case.
# Anything else is the broad publisher query, answered from the fixture.
for a in "\$@"; do
  case "\$a" in
    *ami-dead0000*) echo '{"Images":[]}'; exit 0 ;;
    *ImageIds*)
      id="\$(printf '%s' "\$a" | grep -oE 'ami-[0-9a-z]+' | head -1)"
      printf '{"Images":[{"ImageId":"%s","ImageName":"Ubuntu-22.04-pinned","CreationDate":"2026-01-01T00:00:00Z","RootDeviceType":"bsu","Architecture":"x86_64","State":"available"}]}\\n' "\$id"
      exit 0 ;;
  esac
done
cat "$ROOT/tests/fixtures/readimages-ubuntu.json"
STUB

# --- stub packer: record the args it was handed, then succeed
# Records its arguments. On `build`, and only when STUB_MANIFEST is set, it also
# writes a plausible manifest so the wrapper reaches its post-build steps (OMI-id
# extraction, old/ purge). Without it, the build looks like it produced nothing.
cat > "$STUBS/packer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PACKER_ARGS_LOG:?}"
if [[ "${1:-}" == "build" && -n "${STUB_MANIFEST:-}" ]]; then
  printf '%s\n' '{"builds":[{"artifact_id":"eu-west-2:ami-0badc0de","packer_run_uuid":"u1"}],"last_run_uuid":"u1"}' \
    > "${MANIFEST_FILE:?}"
fi
exit 0
STUB
chmod +x "$STUBS/oapi-cli" "$STUBS/packer"

# The wrapper reads _my_env.sh and needs a readable key; give it a throwaway one.
FAKE_KEY="$STUBS/key"; ssh-keygen -q -t rsa -b 2048 -N '' -f "$FAKE_KEY" </dev/null >/dev/null 2>&1

ARGS_LOG="$STUBS/packer-args"
WRAP_OUT="$STUBS/wrapper-out"
WRAP_RC=0

# Runs the wrapper with the stubs on PATH. Output and the packer arguments land in
# files, not in variables: a command substitution would put them in a subshell.
run_wrapper() {
  : > "$ARGS_LOG"
  WRAP_RC=0
  env PATH="$STUBS:$PATH" PACKER_ARGS_LOG="$ARGS_LOG" \
      OUTSCALE_SSH_KEY="$FAKE_KEY" FETCH_OPTS=--skip-version-check \
      MANIFEST_FILE="$STUBS/manifest.json" ENV_FILE="$STUBS/_my_env.out" "$@" \
      bash -c "cd '$ROOT/build_scripts' && ./build_and_deploy_redis_image_with_packer.sh" \
      > "$WRAP_OUT" 2>&1 || WRAP_RC=$?
}
out()  { cat "$WRAP_OUT"; }
args() { cat "$ARGS_LOG"; }

# ---------- default: resolve the newest Ubuntu 22.04 ----------
run_wrapper

it "announces that it is resolving the newest Ubuntu"
assert_contains "$(out)" "Recherche de la dernière Ubuntu 22.04"

it "picks the newest image from the fixture, not a hardcoded id"
assert_contains "$(out)" "ami-88dbc914"

it "passes the resolved id to packer as -var source_omi"
assert_contains "$(args)" 'source_omi=ami-88dbc914'

it "passes the image name too, for the OMI tags"
assert_contains "$(args)" 'source_omi_name=Ubuntu-22.04-2026-08-10'

it "runs packer validate WITH the build vars -- the bug was validating with none"
assert_status 0 grep -qE 'validate.*source_omi=ami-' "$ARGS_LOG"

it "and reaches packer build"
assert_status 0 grep -q 'build' "$ARGS_LOG"

# ---------- explicit pin, for a Redis-CVE-only rebuild ----------
run_wrapper OUTSCALE_SOURCE_OMI=ami-abc12345

it "honours OUTSCALE_SOURCE_OMI instead of resolving"
assert_contains "$(out)" "(épinglée)"

it "passes the pinned id through to packer"
assert_contains "$(args)" 'source_omi=ami-abc12345'

it "and does not resolve the newest image when pinned"
assert_status 1 grep -q 'ami-88dbc914' "$ARGS_LOG"

# ---------- a pinned id that no longer exists must fail EARLY ----------
run_wrapper OUTSCALE_SOURCE_OMI=ami-dead0000

it "exits non-zero on a deregistered pinned OMI"
assert_eq "1" "$WRAP_RC"

it "says the OMI is introuvable"
assert_contains "$(out)" "introuvable"

it "and never invokes packer at all"
assert_eq "" "$(args)"

# ---------- old/ is purged only once a build has actually succeeded ----------
# Uses the repo's real redis-software/old/ (git-ignored) because the wrapper derives it
# from REPO_ROOT; MANIFEST_FILE is redirected so the repo's own manifest is untouched.
SW="$ROOT/redis-software"
PARKED="$SW/old/redislabs-0.0.0-0-jammy-amd64.tar"

mkdir -p "$SW/old"; echo parked > "$PARKED"
rm -f "$STUBS/manifest.json"
run_wrapper STUB_MANIFEST=1

it "the build succeeds with a valid manifest"
assert_eq "0" "$WRAP_RC"

it "purges redis-software/old/ after a successful build"
assert_contains "$(out)" "purge de redis-software/old/"

it "and the parked tarball is gone -- ~1 GB reclaimed"
assert_status 1 test -f "$PARKED"

it "writes OUTSCALE_AMI_ID to the env file it was given, not the operator's"
assert_contains "$(cat "$STUBS/_my_env.out" 2>/dev/null)" "OUTSCALE_AMI_ID=ami-0badc0de"

# Failing build: no manifest written, so no OMI id can be extracted.
mkdir -p "$SW/old"; echo parked > "$PARKED"
rm -f "$STUBS/manifest.json"
run_wrapper   # no STUB_MANIFEST

it "exits non-zero when the build produced no manifest"
assert_eq "1" "$WRAP_RC"

it "and KEEPS old/ so the previous version can still be retried"
assert_status 0 test -f "$PARKED"

rm -rf "$SW/old"

finish
