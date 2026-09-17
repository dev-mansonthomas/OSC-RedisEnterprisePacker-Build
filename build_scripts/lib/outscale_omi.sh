#!/usr/bin/env bash
# Base-OMI resolution against the Outscale API.
#
# Sourceable library -- defines functions only, runs nothing.
#
# Default behaviour is to resolve the NEWEST official Ubuntu base image at build time,
# so each rebuild ships current kernel and userland patches alongside the new Redis
# Enterprise version. That trades reproducibility for freshness, which is the right
# default when the point of a rebuild is to publish an up-to-date image.
#
# When the point is the opposite -- shipping a Redis Enterprise CVE fix while changing
# as little else as possible -- pin the base with OUTSCALE_SOURCE_OMI=ami-xxxxxxxx and
# the resolution is skipped entirely.
#
# Fetching and parsing are separate so the selection logic is testable without network.

readonly OMI_E_API=5      # oapi-cli missing or the call failed
readonly OMI_E_NOMATCH=6  # call succeeded, nothing matched

: "${UBUNTU_RELEASE:=22.04}"
: "${OMI_ACCOUNT_ALIAS:=Outscale}"
: "${OMI_ARCHITECTURE:=x86_64}"

omi_log() { printf '[omi] %s\n' "$*" >&2; }

# osc_pick_latest_ubuntu <release> -- ReadImages JSON on stdin
# Prints "<id>\t<name>\t<creation-date>" for the newest match. Pure: no network.
#
# Selection is deliberately strict: the builder is outscale-bsu and the build VM type
# is x86, so an instance-store or ARM image would fail late and confusingly.
osc_pick_latest_ubuntu() {
  local release="${1:-$UBUNTU_RELEASE}"
  # 22.04 -> "22[.-]?04", so both Ubuntu-22.04-2026-08-10 and Ubuntu-22-04-... match.
  local pattern="${release//./[.-]?}"
  jq -r --arg pat "$pattern" --arg arch "$OMI_ARCHITECTURE" '
    (.Images // [])
    | map(select(
        (.ImageName // "" | test("ubuntu"; "i"))
        and (.ImageName // "" | test($pat))
        and ((.RootDeviceType // "") == "bsu")
        and ((.Architecture // $arch) == $arch)
        and ((.State // "available") == "available")
      ))
    | sort_by(.CreationDate)
    | last
    | if . == null then empty
      else [.ImageId, .ImageName, .CreationDate] | @tsv
      end
  '
}

# osc_read_images <filters-json> -- raw ReadImages output
osc_read_images() {
  local filters="${1:?osc_read_images: filters required}"
  command -v oapi-cli >/dev/null || { omi_log "oapi-cli absent"; return "$OMI_E_API"; }
  oapi-cli --profile "${OAPI_PROFILE:-default}" ReadImages --Filters "$filters" \
    || { omi_log "ReadImages failed"; return "$OMI_E_API"; }
}

# osc_latest_ubuntu_omi -- "<id>\t<name>\t<date>" for the newest official Ubuntu image
osc_latest_ubuntu_omi() {
  local json result
  json="$(osc_read_images "$(jq -nc \
      --arg alias "$OMI_ACCOUNT_ALIAS" --arg arch "$OMI_ARCHITECTURE" \
      '{AccountAliases:[$alias],Architectures:[$arch],States:["available"]}')")" || return $?
  result="$(printf '%s' "$json" | osc_pick_latest_ubuntu "$UBUNTU_RELEASE")"
  if [[ -z "$result" ]]; then
    omi_log "no Ubuntu $UBUNTU_RELEASE $OMI_ARCHITECTURE bsu image published by '$OMI_ACCOUNT_ALIAS'"
    return "$OMI_E_NOMATCH"
  fi
  printf '%s' "$result"
}

# osc_omi_describe <ami-id> -- "<id>\t<name>\t<date>" if it exists, else non-zero
osc_omi_describe() {
  local id="${1:?osc_omi_describe: OMI id required}" json
  json="$(osc_read_images "$(jq -nc --arg id "$id" '{ImageIds:[$id]}')")" || return $?
  local out
  out="$(printf '%s' "$json" | jq -r '
    (.Images // []) | if length == 0 then empty
    else .[0] | [.ImageId, .ImageName, (.CreationDate // "?")] | @tsv end')"
  [[ -n "$out" ]] || { omi_log "OMI $id not found"; return "$OMI_E_NOMATCH"; }
  printf '%s' "$out"
}
