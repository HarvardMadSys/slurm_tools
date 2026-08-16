#!/usr/bin/env bash
# Run all slurm_tools test suites and report aggregate results.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILED=()

for t in "${ROOT}"/tests/test_*.sh; do
  name="$(basename "$t")"
  printf '=== %s ===\n' "$name"
  if bash "$t"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
    printf 'FAILED: %s\n' "$name" >&2
  fi
done

printf '\n--- summary ---\n'
printf 'passed: %d\n' "$PASS"
printf 'failed: %d\n' "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'failed suites: %s\n' "${FAILED[*]}" >&2
  exit 1
fi
