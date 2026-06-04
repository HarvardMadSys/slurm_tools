#!/bin/bash
# st — umbrella command for slurm_tools. Dispatches to the per-command scripts.
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _target="$(readlink "$_src")"
  [[ "$_target" == /* ]] && _src="$_target" || _src="$(cd "$(dirname "$_src")" && pwd)/$_target"
done
SLURM_TOOLS_SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
export SLURM_TOOLS_SCRIPT_DIR
unset _src _target

read_version() {
  if [[ -f "${SLURM_TOOLS_SCRIPT_DIR}/VERSION" ]]; then
    tr -d '[:space:]' <"${SLURM_TOOLS_SCRIPT_DIR}/VERSION" | head -n1
  else
    printf 'unknown'
  fi
}

json_escape() {
  local value="${1-}" escaped="" char code i
  local LC_ALL=C

  for ((i = 0; i < ${#value}; i++)); do
    char="${value:i:1}"
    case "$char" in
      '"') escaped+='\"' ;;
      \\) escaped+='\\' ;;
      $'\b') escaped+='\b' ;;
      $'\f') escaped+='\f' ;;
      $'\n') escaped+='\n' ;;
      $'\r') escaped+='\r' ;;
      $'\t') escaped+='\t' ;;
      *)
        printf -v code '%d' "'$char"
        if [[ "$code" -lt 32 ]]; then
          printf -v char '\\u%04x' "$code"
        fi
        escaped+="$char"
        ;;
    esac
  done
  printf '%s' "$escaped"
}

log_usage() {
  local log_file log_dir hostname_value hostname_file timestamp user
  local cwd version slurm_job_id command quoted arg record

  if ! hostname_value="$(hostname 2>/dev/null)" || [[ -z "$hostname_value" ]]; then
    hostname_value="unknown"
  fi
  hostname_value="${hostname_value//$'\t'/ }"
  hostname_value="${hostname_value//$'\n'/ }"
  if [[ -n "${SLURM_TOOLS_USAGE_LOG:-}" ]]; then
    log_file="$SLURM_TOOLS_USAGE_LOG"
  else
    hostname_file="${hostname_value//\//_}"
    log_file="/scratch/st/usage_${hostname_file}.jsonl"
  fi

  if ! timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"; then
    timestamp="unknown"
  fi
  if ! user="$(id -un 2>/dev/null)"; then
    user="${USER:-unknown}"
  fi
  user="${user//$'\t'/ }"
  user="${user//$'\n'/ }"
  if ! cwd="$(pwd -P 2>/dev/null)"; then
    cwd="${PWD:-unknown}"
  fi
  version="$(read_version)"
  slurm_job_id="${SLURM_JOB_ID:--}"

  printf -v command '%q' "st"
  for arg in "$@"; do
    printf -v quoted '%q' "$arg"
    command+=" ${quoted}"
  done

  printf -v record \
    '{"timestamp":"%s","user":"%s","hostname":"%s","cwd":"%s","st_version":"%s","slurm_job_id":"%s","command":"%s"}' \
    "$(json_escape "$timestamp")" \
    "$(json_escape "$user")" \
    "$(json_escape "$hostname_value")" \
    "$(json_escape "$cwd")" \
    "$(json_escape "$version")" \
    "$(json_escape "$slurm_job_id")" \
    "$(json_escape "$command")"

  log_dir="${log_file%/*}"
  [[ "$log_dir" == "$log_file" ]] && log_dir="."
  [[ -z "$log_dir" ]] && log_dir="/"
  mkdir -p -m 1777 -- "$log_dir" 2>/dev/null || return 0

  # Usage tracking is best effort and must never prevent the requested command.
  (
    umask 000
    exec 9>>"$log_file" || exit 0
    if command -v flock >/dev/null 2>&1; then
      flock -w 1 -x 9 || true
    fi
    printf '%s\n' "$record" >&9
  ) 2>/dev/null || true
}

log_usage "$@"

# shellcheck source=lib/slurm_common.sh
source "${SLURM_TOOLS_SCRIPT_DIR}/lib/slurm_common.sh"
SLURM_TOOLS_VERSION="$(slurm_tools_read_version)"

usage() {
  cat <<'EOF'
st — SLURM tools

usage: st <command> [options]

Commands:
  alloc       Grab an interactive allocation (placeholder job, wait, record nodes)
  submit      Submit a batch script (or a placeholder if no script is given)
  partition   Recommend a partition from billing weights and free resources
  nodes       Per-node table of unallocated GPU/CPU/memory
  monitor     SSH to a job's nodes and show your processes
  upgrade     Update slurm_tools from GitHub
  help        Show this help
  version     Show the installed version

Run 'st <command> -h' for command-specific options.
EOF
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  upgrade | help | version | -h | --help | --version | -V) ;;
  *) slurm_tools_maybe_auto_upgrade "$cmd" "$@" ;;
esac

case "$cmd" in
  alloc)
    export SLURM_TOOLS_PROG="st alloc"
    exec bash "${SLURM_TOOLS_SCRIPT_DIR}/libexec/alloc.sh" "$@"
    ;;
  submit)
    export SLURM_TOOLS_PROG="st submit"
    exec bash "${SLURM_TOOLS_SCRIPT_DIR}/libexec/submit.sh" "$@"
    ;;
  partition | part)
    export SLURM_TOOLS_PROG="st partition"
    exec bash "${SLURM_TOOLS_SCRIPT_DIR}/libexec/partition.sh" "$@"
    ;;
  nodes)
    export SLURM_TOOLS_PROG="st nodes"
    exec bash "${SLURM_TOOLS_SCRIPT_DIR}/libexec/nodes.sh" "$@"
    ;;
  monitor)
    export SLURM_TOOLS_PROG="st monitor"
    exec python3 "${SLURM_TOOLS_SCRIPT_DIR}/libexec/monitor.py" "$@"
    ;;
  upgrade)
    export SLURM_TOOLS_PROG="st upgrade"
    exec bash "${SLURM_TOOLS_SCRIPT_DIR}/libexec/upgrade.sh" "$@"
    ;;
  help | -h | --help)
    usage
    ;;
  version | --version | -V)
    printf '%s\n' "$(read_version)"
    ;;
  *)
    printf 'st: unknown command: %s\n\n' "$cmd" >&2
    usage >&2
    exit 1
    ;;
esac
