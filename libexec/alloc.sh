#!/bin/bash
set -euo pipefail

# Resolve the install root (repo top). When invoked via `st`, the dispatcher
# exports SLURM_TOOLS_SCRIPT_DIR; otherwise derive it from this script's path
# (one level up from libexec/).
if [[ -z "${SLURM_TOOLS_SCRIPT_DIR:-}" ]]; then
  _src="${BASH_SOURCE[0]}"
  while [[ -L "$_src" ]]; do
    _target="$(readlink "$_src")"
    [[ "$_target" == /* ]] && _src="$_target" || _src="$(cd "$(dirname "$_src")" && pwd)/$_target"
  done
  SLURM_TOOLS_SCRIPT_DIR="$(cd "$(dirname "$_src")/.." && pwd)"
  unset _src _target
fi
# shellcheck source=../lib/slurm_common.sh
source "${SLURM_TOOLS_SCRIPT_DIR}/lib/slurm_common.sh"

SLURM_TOOLS_VERSION="$(slurm_tools_read_version)"
PROG="${SLURM_TOOLS_PROG:-$(basename "$0")}"
job_id=""

usage() {
  cat <<EOF
usage: ${PROG} [-J JOB_NAME] [-N NODES] [-c CPUS] [-m MEM_GB] [-G GPU_TYPE] [-g GPUS] [-t HOURS] [-p PARTITION]
default values: JOB_NAME derived, NODES=1, CPUS=16, MEM_GB=256, GPU_TYPE=any, GPUS=1, HOURS=12, PARTITION=best
example: ${PROG} -N 2 -c 64 -m 512 -g 4 -G h200 -t 24
gpu types: $(slurm_tools_gpu_types_help)

Environment: SLURM_TOOLS_ALLOC_SCRIPT, SLURM_TOOLS_MIG_PARTITION,
  SLURM_TOOLS_SKIP_UPGRADE, SLURM_TOOLS_FORCE_UPGRADE_CHECK

Options:
  -J, --job-name NAME    Job name (default: derived from GPU count/type or username)
  -N, --nodes N          Number of nodes (default: 1)
  -c, --cpus N           CPU cores per node (default: 16)
  -m, --mem GB           Memory per node in GB (default: 256)
  -G, --gpu-type TYPE    GPU type (default: any GPU type)
  -g, --gpus N           GPUs per node (default: 1; use 0 for CPU-only)
  -t, --time HOURS       Wall time in hours (default: 12)
  -p, --partition NAME   Partition (default: best; auto-selects via 'st partition' logic)
      --version          Show version
  -h, --help             Show this help message
EOF
  exit 1
}

on_interrupt() {
  echo "Ctrl+C pressed, cancelling job..."
  if [[ -n "${job_id:-}" ]]; then
    scancel "$job_id" 2>/dev/null || true
  fi
  exit 1
}

slurm_tools_set_job_defaults
slurm_tools_parse_job_args usage "$@"
if [[ "${#SLURM_TOOLS_POSITIONAL[@]}" -gt 0 ]]; then
  slurm_tools_print_log "unexpected argument: ${SLURM_TOOLS_POSITIONAL[0]} (st alloc takes no script; use 'st submit' to run one)"
  usage
fi

trap on_interrupt INT

slurm_tools_prepare_job

ALLOC_SCRIPT="$(slurm_tools_alloc_script)"
if [[ ! -f "$ALLOC_SCRIPT" ]]; then
  slurm_tools_print_log "alloc script not found: ${ALLOC_SCRIPT} (set SLURM_TOOLS_ALLOC_SCRIPT)"
  exit 1
fi

if ! slurm_tools_sbatch -p "${PARTITION}" \
  -J "${JOB_NAME}" \
  --nodes="${NODE_COUNT}" \
  --ntasks-per-node=1 \
  --mem="${MEM_GB}g" \
  --time="${TIMEOUT_STRING}" \
  -c "${CPU_CORE}" \
  --mail-type=ALL \
  --output=logs/%x.%j.out \
  --error=logs/%x.%j.err \
  "${GRES_ARGS[@]}" \
  "$ALLOC_SCRIPT"; then
  slurm_tools_print_log "sbatch failed"
  exit 1
fi
job_id="${SLURM_TOOLS_JOB_ID}"
slurm_tools_print_log "job_id: ${job_id}, waiting for job to start"

printf '\n'
if ! slurm_tools_wait_for_allocation "$job_id" "$JOB_NAME"; then
  printf '\n'
  slurm_tools_print_log "allocation failed or job ended"
  exit 1
fi
printf '\n'
