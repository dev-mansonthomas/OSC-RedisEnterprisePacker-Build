#!/usr/bin/env bash
# Check which Redis Enterprise Software tarball is present in redis-software/,
# compare it against the latest published release, and optionally download.
#
# Credential-free: version discovery scrapes public release notes and the download
# bucket serves the tarball anonymously. Safe to run inside the VM.
#
# Usage:
#   ./fetch_redis_tarball.sh                     # report only; never fails on staleness
#   ./fetch_redis_tarball.sh --download          # fetch the latest if absent
#   ./fetch_redis_tarball.sh --version 8.2.0-78  # pin explicitly, skip discovery
#   ./fetch_redis_tarball.sh --require-latest    # exit 1 if not on the latest (CI)
#   ./fetch_redis_tarball.sh --skip-version-check  # only validate what is on disk
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/redis_version.sh
source "$REPO_ROOT/build_scripts/lib/redis_version.sh"

SOFTWARE_DIR="$REPO_ROOT/redis-software"
SUMS_FILE="$SOFTWARE_DIR/SHA256SUMS"

DO_DOWNLOAD=0
REQUIRE_LATEST=0
SKIP_CHECK=0
PIN_VERSION=""

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download)           DO_DOWNLOAD=1; shift ;;
    --require-latest)     REQUIRE_LATEST=1; shift ;;
    --skip-version-check) SKIP_CHECK=1; shift ;;
    --version)            PIN_VERSION="${2:?--version needs a value}"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit "$RCV_E_USAGE" ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$SOFTWARE_DIR"

# ---------------------------------------------------------------- local inventory
# T-05: more than one tarball is ambiguous. The old code silently took the
# alphabetically first, which is usually the OLDER version.
shopt -s nullglob
LOCAL_TARBALLS=("$SOFTWARE_DIR"/redislabs-*.tar)
shopt -u nullglob

LOCAL_VERSION=""
LOCAL_FILE=""
case "${#LOCAL_TARBALLS[@]}" in
  0) say "No tarball in redis-software/." ;;
  1)
    LOCAL_FILE="${LOCAL_TARBALLS[0]}"
    LOCAL_VERSION="$(rcv_version_from_filename "$LOCAL_FILE")" \
      || die "redis-software/ holds a tarball whose name cannot be parsed: $(basename "$LOCAL_FILE")"
    say "Local:  $LOCAL_VERSION  ($(basename "$LOCAL_FILE"))"
    ;;
  *)
    printf 'Found %d tarballs in redis-software/:\n' "${#LOCAL_TARBALLS[@]}" >&2
    printf '  %s\n' "${LOCAL_TARBALLS[@]##*/}" >&2
    die "ambiguous -- keep exactly one, or pass --version to say which to use"
    ;;
esac

# ---------------------------------------------------------- digest bookkeeping
# No upstream checksum or signature is published alongside the tarball (verified:
# .sha256/.md5/.sig/.asc all return HTTP 403), so the best available integrity
# story is: record the digest on first download, verify against it afterwards.
record_digest() {
  local file="$1" sum
  sum="$(sha256sum "$file" | cut -d' ' -f1)"
  touch "$SUMS_FILE"
  if grep -q "  $(basename "$file")\$" "$SUMS_FILE" 2>/dev/null; then
    local known
    known="$(grep "  $(basename "$file")\$" "$SUMS_FILE" | cut -d' ' -f1)"
    if [[ "$known" != "$sum" ]]; then
      die "DIGEST MISMATCH for $(basename "$file")
       recorded: $known
       actual:   $sum
       The file changed since it was recorded. Do not build from it."
    fi
    say "Digest: verified against $(basename "$SUMS_FILE")"
  else
    printf '%s  %s\n' "$sum" "$(basename "$file")" >> "$SUMS_FILE"
    say "Digest: recorded $sum"
  fi
}

# ---------------------------------------------------------------- what is latest
LATEST_VERSION=""
if (( SKIP_CHECK )); then
  say "Version check skipped."
elif [[ -n "$PIN_VERSION" ]]; then
  rcv_is_valid_version "$PIN_VERSION" \
    || die "--version '$PIN_VERSION' is malformed (want <maj>.<min>.<patch>-<build>)"
  LATEST_VERSION="$PIN_VERSION"
  say "Target: $LATEST_VERSION  (pinned)"
else
  if LATEST_VERSION="$(rcv_latest_version)"; then
    say "Latest: $LATEST_VERSION  (from redis.io release notes)"
  else
    rc=$?
    LATEST_VERSION=""
    # Discovery is HTML scraping: degrade, never block a build on it.
    warn "could not determine the latest version (exit $rc)."
    warn "Pass --version <x.y.z-b> to pin, or --skip-version-check to ignore."
    (( REQUIRE_LATEST )) && die "--require-latest given but discovery failed"
  fi
fi

# ------------------------------------------------------------------- download
TARGET_FILE=""
if [[ -n "$LATEST_VERSION" ]]; then
  TARGET_FILE="$SOFTWARE_DIR/$(rcv_tarball_name "$LATEST_VERSION")"
fi

if (( DO_DOWNLOAD )) && [[ -n "$LATEST_VERSION" ]] && [[ ! -f "$TARGET_FILE" ]]; then
  url="$(rcv_tarball_url "$LATEST_VERSION")"
  say "Downloading $LATEST_VERSION"
  say "  from $url"
  # .part + mv so an interrupted transfer never looks like a complete tarball;
  # --continue-at - resumes it instead of restarting 350 MB-1 GB.
  # shellcheck disable=SC2086
  curl --fail --location --progress-bar --continue-at - \
       --retry 3 --retry-delay 5 \
       --output "$TARGET_FILE.part" "$url" \
    || die "download failed: $url"

  expected="$(curl --silent --head --location "$url" \
              | awk 'tolower($1) ~ /^content-length:/ {print $2}' | tr -d '\r' | tail -1)"
  actual="$(stat -c %s "$TARGET_FILE.part" 2>/dev/null || stat -f %z "$TARGET_FILE.part")"
  if [[ -n "$expected" && "$expected" != "$actual" ]]; then
    die "size mismatch: expected $expected bytes, got $actual. Left at $TARGET_FILE.part"
  fi
  mv "$TARGET_FILE.part" "$TARGET_FILE"
  say "Saved   $(basename "$TARGET_FILE")  ($actual bytes)"
  record_digest "$TARGET_FILE"

  # Replaces the local inventory: the freshly downloaded one is now authoritative.
  if [[ -n "$LOCAL_FILE" && "$LOCAL_FILE" != "$TARGET_FILE" ]]; then
    warn "an older tarball is still present: $(basename "$LOCAL_FILE")"
    warn "remove it -- the build refuses to run with more than one."
  fi
  LOCAL_FILE="$TARGET_FILE"
  LOCAL_VERSION="$LATEST_VERSION"
elif [[ -n "$LOCAL_FILE" ]]; then
  record_digest "$LOCAL_FILE"
fi

# --------------------------------------------------------------------- verdict
if [[ -z "$LOCAL_FILE" ]]; then
  if [[ -n "$LATEST_VERSION" ]]; then
    say ""
    say "Nothing to build from. Either:"
    say "  ./build_scripts/fetch_redis_tarball.sh --download"
    say "  or download it manually to redis-software/:"
    say "    $(rcv_tarball_url "$LATEST_VERSION")"
  fi
  die "no Redis Enterprise tarball in redis-software/"
fi

if [[ -n "$LATEST_VERSION" && "$LOCAL_VERSION" != "$LATEST_VERSION" ]]; then
  cmp="$(rcv_compare_versions "$LOCAL_VERSION" "$LATEST_VERSION")"
  if [[ "$cmp" == "-1" ]]; then
    warn "local $LOCAL_VERSION is behind $LATEST_VERSION"
    warn "  get it: ./build_scripts/fetch_redis_tarball.sh --download"
    (( REQUIRE_LATEST )) && die "--require-latest: refusing to build $LOCAL_VERSION"
  else
    say "Local $LOCAL_VERSION is ahead of the detected $LATEST_VERSION (pre-release?)."
  fi
else
  [[ -n "$LATEST_VERSION" ]] && say "Up to date."
fi

# Consumed by the build wrapper.
printf 'REDIS_VERSION=%s\n' "$LOCAL_VERSION"
