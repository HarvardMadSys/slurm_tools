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
