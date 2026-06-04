#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG="${TMP}/usage_$(hostname).jsonl"
USER_NAME="$(id -un)"
HOST_NAME="$(hostname)"
CWD_VALUE="$(pwd -P)"
VERSION="$(tr -d '[:space:]' <"${ROOT}/VERSION")"
ODD_ARGS=("bad command" $'line\nbreak' $'quote" slash\\ tab\tend')
printf -v EXPECTED_COMMAND '%q' "st"
for arg in "${ODD_ARGS[@]}"; do
  printf -v quoted '%q' "$arg"
  EXPECTED_COMMAND+=" ${quoted}"
done

SLURM_JOB_ID=12345 SLURM_TOOLS_USAGE_LOG="$LOG" "${ROOT}/st.sh" version >/dev/null

set +e
env -u SLURM_JOB_ID SLURM_TOOLS_USAGE_LOG="$LOG" \
  "${ROOT}/st.sh" "${ODD_ARGS[@]}" >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]]

python3 - "$LOG" "$USER_NAME" "$HOST_NAME" "$CWD_VALUE" "$VERSION" "$EXPECTED_COMMAND" <<'PY'
import json
import re
import sys

log, user, hostname, cwd, version, expected_command = sys.argv[1:]
with open(log) as f:
    records = [json.loads(line) for line in f]

assert len(records) == 2
assert list(records[0]) == [
    "timestamp", "user", "hostname", "cwd", "st_version", "slurm_job_id", "command"
]
assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", records[0]["timestamp"])
assert records[0]["user"] == user
assert records[0]["hostname"] == hostname
assert records[0]["cwd"] == cwd
assert records[0]["st_version"] == version
assert records[0]["slurm_job_id"] == "12345"
assert records[0]["command"] == "st version"
assert records[1]["slurm_job_id"] == "-"
assert records[1]["command"] == expected_command
PY

[[ "$(stat -c %a "$LOG")" == "666" ]]

PARALLEL_LOG="${TMP}/parallel.log"
pids=()
for _ in {1..20}; do
  env -u SLURM_JOB_ID SLURM_TOOLS_USAGE_LOG="$PARALLEL_LOG" \
    "${ROOT}/st.sh" version >/dev/null &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid"
done
[[ "$(wc -l <"$PARALLEL_LOG")" -eq 20 ]]
python3 - "$PARALLEL_LOG" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    records = [json.loads(line) for line in f]
assert len(records) == 20
assert all(record["command"] == "st version" for record in records)
PY

output="$(SLURM_TOOLS_USAGE_LOG=/proc/st/usage.jsonl "${ROOT}/st.sh" version)"
[[ "$output" == "$(tr -d '[:space:]' <"${ROOT}/VERSION")" ]]

printf 'usage logging tests passed\n'
