#!/usr/bin/env bash
# Runs every tests/test_*.sh. Credential-free; safe in the VM and in CI.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

failed=0
shopt -s nullglob
files=(test_*.sh)
if (( ${#files[@]} == 0 )); then
  echo "no tests found" >&2; exit 1
fi

for t in "${files[@]}"; do
  printf '\n\033[1m==> %s\033[0m\n' "$t"
  bash "$t" || failed=1
done

printf '\n'
if (( failed )); then printf '\033[31mTEST SUITE FAILED\033[0m\n'; exit 1; fi
printf '\033[32mALL TESTS PASSED\033[0m\n'
