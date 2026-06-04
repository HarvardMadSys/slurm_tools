#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG="${TMP}/usage_$(hostname).log"
USER_NAME="$(id -un)"

SLURM_TOOLS_USAGE_LOG="$LOG" "${ROOT}/st.sh" version >/dev/null

set +e
SLURM_TOOLS_USAGE_LOG="$LOG" "${ROOT}/st.sh" "bad command" $'line\nbreak' >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]

[[ "$(wc -l <"$LOG")" -eq 2 ]]
IFS=$'\t' read -r timestamp user command <"$LOG"
[[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
[[ "$user" == "$USER_NAME" ]]
[[ "$command" == "st version" ]]

second_record="$(sed -n '2p' "$LOG")"
[[ "$second_record" == *$'\t'"${USER_NAME}"$'\t'"st bad\\ command "* ]]
[[ "$second_record" == *'line\nbreak'* ]]
[[ "$(stat -c %a "$LOG")" == "666" ]]

PARALLEL_LOG="${TMP}/parallel.log"
pids=()
for _ in {1..20}; do
  SLURM_TOOLS_USAGE_LOG="$PARALLEL_LOG" "${ROOT}/st.sh" version >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
[[ "$(wc -l <"$PARALLEL_LOG")" -eq 20 ]]

output="$(SLURM_TOOLS_USAGE_LOG=/proc/st/usage.log "${ROOT}/st.sh" version)"
[[ "$output" == "$(tr -d '[:space:]' <"${ROOT}/VERSION")" ]]

printf 'usage logging tests passed\n'
