#!/usr/bin/env bash
# Minimal assertion helpers. No external dependency: bats is not installed in the VM
# and the assertions we need are simple. Source this from tests/test_*.sh.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

it() { CURRENT_TEST="$1"; TESTS_RUN=$((TESTS_RUN + 1)); }

_pass() { printf '  \033[32m✓\033[0m %s\n' "$CURRENT_TEST"; }
_fail() {
  printf '  \033[31m✗\033[0m %s\n' "$CURRENT_TEST"
  printf '      %s\n' "$@"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_eq() {
  local expected="$1" actual="$2"
  if [[ "$expected" == "$actual" ]]; then _pass
  else _fail "expected: '$expected'" "  actual: '$actual'"; fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then _pass
  else _fail "expected to contain: '$needle'" "             actual: '$haystack'"; fi
}

# assert_status <expected-code> <command...>
assert_status() {
  local expected="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$rc" == "$expected" ]]; then _pass
  else _fail "expected exit $expected, got $rc" "output: $out"; fi
}

finish() {
  printf '\n'
  if (( TESTS_FAILED )); then
    printf '\033[31m%d/%d failed\033[0m in %s\n' "$TESTS_FAILED" "$TESTS_RUN" "$(basename "$0")"
    exit 1
  fi
  printf '\033[32m%d/%d passed\033[0m in %s\n' "$TESTS_RUN" "$TESTS_RUN" "$(basename "$0")"
}
