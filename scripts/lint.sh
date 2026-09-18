#!/usr/bin/env bash
# Credential-free static checks. Runs identically in the Colima VM and in CI.
# Usage: ./scripts/lint.sh [--no-packer]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

RUN_PACKER=1
UPDATE_BASELINE=0
for arg in "$@"; do
  case "$arg" in
    --no-packer)               RUN_PACKER=0 ;;
    --update-drift-baseline)   UPDATE_BASELINE=1 ;;
    -h|--help) echo "usage: $0 [--no-packer] [--update-drift-baseline]"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

fail=0
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '    \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

# ---------- shellcheck ----------
step "shellcheck"
if command -v shellcheck >/dev/null; then
  # shellcheck disable=SC2046  # intentional word splitting over the file list
  mapfile -t SH_FILES < <(git ls-files '*.sh' | grep -v '^_my_env')
  # -S warning: info-level hints (SC2012/SC2317) are tracked in docs/TODO.md T-39,
  # not gates. Errors and warnings block.
  if shellcheck -S warning -x "${SH_FILES[@]}"; then
    ok "${#SH_FILES[@]} shell files clean"
  else
    bad "shellcheck reported findings"
  fi
else
  bad "shellcheck not installed"
fi

# ---------- packer ----------
if (( RUN_PACKER )); then
  step "packer fmt / init / validate"
  PKR_FILE="packer/redis_ubuntu_outscale_image.pkr.hcl"
  LINT_REGION="${LINT_REGION:-eu-west-2}"
  # Placeholder: lint checks the template, not that this image exists.
  LINT_SOURCE_OMI="${LINT_SOURCE_OMI:-ami-00000000}"

  # Use whichever tarball is on disk, if any. Deliberately NOT `ls | sed`: ls exits 2
  # when the glob matches nothing, and pipefail turns that into an abort -- which is
  # exactly how this script passed locally (tarball present) and failed in CI (absent).
  shopt -s nullglob
  _tarballs=(redis-software/redislabs-*.tar)
  shopt -u nullglob
  LINT_REDIS_VERSION=""
  if (( ${#_tarballs[@]} )); then
    LINT_REDIS_VERSION="$(basename "${_tarballs[0]}" \
      | sed -nE 's#^redislabs-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*#\1#p')"
  fi
  : "${LINT_REDIS_VERSION:=0.0.0-0}"

  # `packer validate` prepares the file provisioners, so their sources must exist. In CI
  # the tarball is git-ignored and absent; stand in an empty file so the template is
  # still really validated, and remove only what we created.
  LINT_STUB_TARBALL="redis-software/redislabs-${LINT_REDIS_VERSION}-jammy-amd64.tar"
  LINT_STUB_CREATED=0
  if [[ ! -e "$LINT_STUB_TARBALL" ]]; then
    mkdir -p redis-software
    : > "$LINT_STUB_TARBALL"
    LINT_STUB_CREATED=1
  fi
  cleanup_stub_tarball() {
    (( LINT_STUB_CREATED )) && rm -f "$LINT_STUB_TARBALL"
    LINT_STUB_CREATED=0
  }
  trap cleanup_stub_tarball EXIT
  if command -v packer >/dev/null; then
    if packer fmt -check -diff packer/; then
      ok "packer fmt"
    else
      bad "packer fmt -check (run: packer fmt packer/)"
    fi
    # init downloads the plugin; both init and validate are credential-free.
    # validate insists on a readable ssh_private_key_file and a well-formed
    # redis_version, so feed it a throwaway key and a placeholder version -- we are
    # checking the template, not the configuration.
    if packer init "$PKR_FILE" >/dev/null; then
      ok "packer init"
    else
      bad "packer init (plugin download failed?)"
    fi

    FAKE_KEY="$(mktemp -u)"
    ssh-keygen -q -t rsa -b 2048 -N '' -f "$FAKE_KEY" </dev/null >/dev/null 2>&1
    if packer validate \
         -var "region=$LINT_REGION" \
         -var "keypair_private_file=$FAKE_KEY" \
         -var "keypair_name=lint-placeholder" \
         -var "redis_version=$LINT_REDIS_VERSION" \
         -var "source_omi=$LINT_SOURCE_OMI" \
         "$PKR_FILE" >/dev/null; then
      ok "packer validate (region=$LINT_REGION)"
    else
      bad "packer validate"
      packer validate -var "region=$LINT_REGION" -var "keypair_private_file=$FAKE_KEY" \
        -var "keypair_name=lint-placeholder" -var "redis_version=$LINT_REDIS_VERSION" \
        -var "source_omi=$LINT_SOURCE_OMI" "$PKR_FILE" 2>&1 | sed 's/^/           /' | head -20
    fi
    rm -f "$FAKE_KEY" "$FAKE_KEY.pub"
    cleanup_stub_tarball

    # The redis_version validation block must actually reject a bad value, or the
    # guard is decorative.
    if packer validate -var "region=$LINT_REGION" -var "keypair_private_file=/dev/null" \
         -var "keypair_name=k" -var "redis_version=not-a-version" \
         -var "source_omi=$LINT_SOURCE_OMI" "$PKR_FILE" >/dev/null 2>&1; then
      bad "the redis_version validation block does NOT reject a malformed version"
    else
      ok "redis_version validation rejects a malformed value"
    fi
  else
    printf '    \033[33mSKIP\033[0m packer not installed in this environment\n'
    printf '           add "packer" to scripts/vm-provision.sh of the dev-setup repo\n'
  fi
fi

# ---------- drift guard against the Run repo (R-01) ----------
# osc-setup.sh / tear_down_outscale.sh exist in both repos and must not diverge by
# ACCIDENT. Known, deliberate divergence is recorded in scripts/shared-drift.baseline;
# CI fails only when the actual drift stops matching that baseline -- i.e. on NEW drift.
# Comment-only differences are ignored entirely.
# Refresh the baseline on purpose with: ./scripts/lint.sh --update-drift-baseline
step "shared-script drift vs OSC-RedisEnterprisePacker-Run"
RUN_REPO="${RUN_REPO:-$REPO_ROOT/../OSC-RedisEnterprisePacker-Run}"
SHARED=(osc/osc-setup.sh osc/tear_down_outscale.sh)
BASELINE="scripts/shared-drift.baseline"

strip_noise() { sed -E 's/[[:space:]]+$//; s/^[[:space:]]*#.*$//' "$1" | grep -v '^$'; }

current_drift() {
  for f in "${SHARED[@]}"; do
    [[ -f "$RUN_REPO/$f" ]] || continue
    printf '### %s\n' "$f"
    diff <(strip_noise "$RUN_REPO/$f") <(strip_noise "$f") || true
  done
}

if [[ ! -d "$RUN_REPO" ]]; then
  printf '    \033[33mSKIP\033[0m Run repo not found at %s (set RUN_REPO=)\n' "$RUN_REPO"
elif [[ "$UPDATE_BASELINE" == 1 ]]; then
  current_drift > "$BASELINE"
  ok "baseline refreshed -> $BASELINE ($(grep -c '^' "$BASELINE") lines)"
else
  DRIFT="$(current_drift)"
  if [[ ! -f "$BASELINE" ]]; then
    bad "$BASELINE missing (create it: ./scripts/lint.sh --update-drift-baseline)"
  elif [[ "$DRIFT" == "$(cat "$BASELINE")" ]]; then
    if [[ -s "$BASELINE" && "$(grep -cv '^### ' "$BASELINE")" -gt 0 ]]; then
      printf '    \033[33mWARN\033[0m drift matches the recorded baseline (see R-01)\n'
    else
      ok "no drift"
    fi
  else
    bad "NEW drift vs the Run repo -- reconcile, or refresh the baseline deliberately"
    diff <(cat "$BASELINE") <(printf '%s\n' "$DRIFT") | sed 's/^/           /' | head -25
  fi
fi

# ---------- no secrets / personal paths in tracked files ----------
# Docs legitimately quote placeholder key material and example paths, so *.md is
# excluded. Everything else that ships must be free of personal absolute paths and
# of anything shaped like private key material.
step "tracked files carry no secrets or personal paths"
mapfile -t SCAN_FILES < <(git ls-files -- ':!*.md' ':!scripts/shared-drift.baseline')
# /home/outscale and /home/ubuntu are the legitimate GUEST paths inside the build VM.
# What must never ship is a HOST path naming a person, or key material.
GUEST_USERS='outscale|ubuntu|root|lima'
HITS=""
if (( ${#SCAN_FILES[@]} )); then
  HITS="$(grep -nIE '/(Users|home)/[a-z][a-z._-]+/|BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY' \
            "${SCAN_FILES[@]}" 2>/dev/null \
          | grep -vE "/home/($GUEST_USERS)/" || true)"
fi
if [[ -n "$HITS" ]]; then
  bad "personal absolute path or private-key material in a tracked file"
  printf '%s\n' "$HITS" | sed 's/^/           /'
else
  ok "${#SCAN_FILES[@]} tracked non-doc files clean"
fi

step "result"
if (( fail )); then
  printf '\033[31mlint FAILED\033[0m\n'; exit 1
fi
printf '\033[32mlint passed\033[0m\n'
