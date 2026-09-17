#!/usr/bin/env bash
# Redis Enterprise Software version discovery and tarball URL construction.
#
# Sourceable library -- defines functions only, runs nothing.
#
# Adapted from redis-enterprise-multicloud-terraform/scripts/get_latest_redis_version.sh,
# with three bugs from the original fixed:
#   1. `local x=$(cmd)` sets $? from the `local` builtin, not from `cmd`, so the
#      original's `if [ $? -ne 0 ]` checks could never fire. Assignment and capture
#      are now separated.
#   2. `set -e` without `-o pipefail` let a failing curl in a pipeline pass silently.
#   3. No curl timeout: a hung fetch blocked the build indefinitely.
#
# Discovery scrapes redis.io HTML and is therefore inherently brittle. It fails with
# a distinct exit code so callers can degrade instead of dying -- see RCV_E_* below.

# Exit codes, so callers can tell "no network" from "page layout changed".
readonly RCV_E_FETCH=3     # network/HTTP problem
readonly RCV_E_PARSE=4     # fetched fine, but the expected pattern was absent
readonly RCV_E_USAGE=2

: "${REDIS_RELEASE_NOTES_URL:=https://redis.io/docs/latest/operate/rs/release-notes/}"
: "${REDIS_DOWNLOAD_BASE_URL:=https://s3.amazonaws.com/redis-enterprise-software-downloads}"
: "${REDIS_PLATFORM:=jammy-amd64}"
: "${RCV_CURL_OPTS:=--silent --show-error --location --max-time 20 --retry 2 --retry-delay 2}"

rcv_log() { printf '[redis-version] %s\n' "$*" >&2; }

# rcv_fetch <url> -- body on stdout
rcv_fetch() {
  local url="$1" body
  # shellcheck disable=SC2086  # RCV_CURL_OPTS is a deliberate option list
  if ! body="$(curl $RCV_CURL_OPTS "$url")"; then
    rcv_log "ERROR: could not fetch $url"
    return "$RCV_E_FETCH"
  fi
  printf '%s' "$body"
}

# rcv_latest_major -- e.g. "8.2"
rcv_latest_major() {
  local html major
  html="$(rcv_fetch "$REDIS_RELEASE_NOTES_URL")" || return $?
  major="$(printf '%s' "$html" | grep -oE '[0-9]+\.[0-9]+\.x releases' | head -1 | sed 's/\.x releases//')"
  if [[ -z "$major" ]]; then
    rcv_log "ERROR: no '<maj>.<min>.x releases' pattern at $REDIS_RELEASE_NOTES_URL"
    rcv_log "       the page layout probably changed; pass an explicit --version"
    return "$RCV_E_PARSE"
  fi
  printf '%s' "$major"
}

# rcv_latest_full <major> -- e.g. "8.2.0-78"
rcv_latest_full() {
  local major="${1:?rcv_latest_full: major version required}"
  local url html full
  url="${REDIS_RELEASE_NOTES_URL}rs-${major//./-}-releases/"
  html="$(rcv_fetch "$url")" || return $?
  full="$(printf '%s' "$html" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+ \(' | head -1 | sed 's/ ($//;s/ ($//;s/ (//')"
  if [[ -z "$full" ]]; then
    rcv_log "ERROR: no '<maj>.<min>.<patch>-<build> (' pattern at $url"
    return "$RCV_E_PARSE"
  fi
  printf '%s' "$full"
}

# rcv_latest_version -- the full latest version, e.g. "8.2.0-78"
rcv_latest_version() {
  local major full
  major="$(rcv_latest_major)" || return $?
  full="$(rcv_latest_full "$major")" || return $?
  printf '%s' "$full"
}

# rcv_is_valid_version <string> -- the shape the rest of the build relies on
rcv_is_valid_version() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]
}

# rcv_tarball_name <full-version> -- redislabs-8.2.0-78-jammy-amd64.tar
rcv_tarball_name() {
  local v="${1:?rcv_tarball_name: version required}"
  rcv_is_valid_version "$v" || { rcv_log "ERROR: malformed version '$v'"; return "$RCV_E_USAGE"; }
  printf 'redislabs-%s-%s.tar' "$v" "$REDIS_PLATFORM"
}

# rcv_tarball_url <full-version>
# The directory component drops the build number while the filename keeps it:
#   .../8.2.0/redislabs-8.2.0-78-jammy-amd64.tar
# Verified against 8.2.0-78, 8.0.2-41 and 7.22.0-95 (all HTTP 200).
rcv_tarball_url() {
  local v="${1:?rcv_tarball_url: version required}" name
  name="$(rcv_tarball_name "$v")" || return $?
  printf '%s/%s/%s' "$REDIS_DOWNLOAD_BASE_URL" "${v%%-*}" "$name"
}

# rcv_version_from_filename <path-or-filename> -- "8.0.2-41", or empty + non-zero
# Unlike the original inline sed, a non-matching name yields EMPTY rather than the
# basename unchanged, so callers can actually detect the failure (TODO T-05).
rcv_version_from_filename() {
  local base v
  base="$(basename "${1:?rcv_version_from_filename: path required}")"
  v="$(printf '%s' "$base" | sed -nE 's/^redislabs-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*\.tar$/\1/p')"
  if [[ -z "$v" ]]; then
    rcv_log "ERROR: '$base' does not match redislabs-<maj>.<min>.<patch>-<build>-<platform>.tar"
    return "$RCV_E_PARSE"
  fi
  printf '%s' "$v"
}

# rcv_compare_versions <a> <b> -- prints -1 if a<b, 0 if equal, 1 if a>b
rcv_compare_versions() {
  local a="${1:?}" b="${2:?}"
  [[ "$a" == "$b" ]] && { printf '0'; return 0; }
  # numeric field-wise compare over maj.min.patch-build
  local first
  first="$(printf '%s\n%s\n' "${a//-/.}" "${b//-/.}" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)"
  if [[ "$first" == "${a//-/.}" ]]; then printf '%s' '-1'; else printf '1'; fi
}
