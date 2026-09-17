#!/usr/bin/env bash
# Managed blocks inside _my_env.sh.
#
# Sourceable library -- defines functions only, runs nothing.
#
# _my_env.sh is the interface between osc-setup.sh, the build wrapper and the
# OSC-RedisEnterprisePacker-Run repo. Every script used to APPEND to it, so a second
# run left two conflicting blocks and `source` silently kept the last one. For
# OUTSCALE_AMI_ID that means a stale entry launches the WRONG IMAGE (TODO T-01).
#
# Each writer owns a named block delimited by sentinels and rewrites it in place:
#
#   # >>> generated: outscale-net >>>
#   OSC_NET_ID=vpc-...
#   # <<< generated: outscale-net <<<
#
# Writes go through a temp file + mv so an interrupted run cannot truncate the
# operator's configuration.

env_block_begin() { printf '# >>> generated: %s >>>' "$1"; }
env_block_end()   { printf '# <<< generated: %s <<<' "$1"; }

# env_write_block <env-file> <block-name> [KEY=VALUE ...]
# Replaces the named block in place, or appends it if absent. Idempotent.
env_write_block() {
  local file="${1:?env_write_block: env file required}"
  local name="${2:?env_write_block: block name required}"
  shift 2

  local begin end tmp
  begin="$(env_block_begin "$name")"
  end="$(env_block_end "$name")"
  [[ -f "$file" ]] || : > "$file"
  tmp="$(mktemp "${file}.XXXXXX")"

  # Copy everything outside the block, dropping any previous copies of it.
  awk -v b="$begin" -v e="$end" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    !inblock { print }
  ' "$file" > "$tmp"

  # Drop trailing blank lines, then emit exactly one before the block.
  awk 'BEGIN{n=0} {lines[NR]=$0} END{
        last=NR; while (last>0 && lines[last] ~ /^[[:space:]]*$/) last--;
        for(i=1;i<=last;i++) print lines[i]
      }' "$tmp" > "$tmp.trimmed" && mv "$tmp.trimmed" "$tmp"

  local need_blank=0
  [[ -s "$tmp" ]] && need_blank=1

  {
    (( need_blank )) && printf '\n'
    printf '%s\n' "$begin"
    local kv
    for kv in "$@"; do printf '%s\n' "$kv"; done
    printf '%s\n' "$end"
  } >> "$tmp"

  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "$file"
}

# env_read_block <env-file> <block-name> -- the block's body on stdout
env_read_block() {
  local file="${1:?}" name="${2:?}" begin end
  begin="$(env_block_begin "$name")"
  end="$(env_block_end "$name")"
  [[ -f "$file" ]] || return 0
  awk -v b="$begin" -v e="$end" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock { print }
  ' "$file"
}

# env_legacy_duplicates <env-file> <key> -- count of unmanaged assignments of <key>
# Used to warn about blocks left behind by the old append-only scripts.
env_legacy_duplicates() {
  local file="${1:?}" key="${2:?}"
  [[ -f "$file" ]] || { printf '0'; return 0; }
  grep -cE "^[[:space:]]*${key}=" "$file" || true
}
