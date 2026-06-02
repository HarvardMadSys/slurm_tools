#!/bin/bash
set -euo pipefail

_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _target="$(readlink "$_src")"
  [[ "$_target" == /* ]] && _src="$_target" || _src="$(cd "$(dirname "$_src")" && pwd)/$_target"
done
SLURM_TOOLS_SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _target
# shellcheck source=lib/slurm_common.sh
source "${SLURM_TOOLS_SCRIPT_DIR}/lib/slurm_common.sh"

SLURM_TOOLS_VERSION="$(slurm_tools_read_version)"
job_id=""

usage() {
  echo "usage: $0 [-j JOB_NAME] [-n NODES] [-c CPU_CORE] [-m MEM_GB] [-u GPU_TYPE] [-g GPU_COUNT] [-t TIMEOUT_HOURS] [-p PARTITION]"
  echo "default values: JOB_NAME=$(whoami) or \${GPU_COUNT}\${GPU_TYPE}, NODES=1, CPU_CORE=16, MEM_GB=256, GPU_TYPE=any, GPU_COUNT=1, TIMEOUT_HOURS=12, PARTITION=best"
  echo "example: $0 -n 2 -c 64 -m 512 -g 4 -u h200 -t 24"
  echo "gpu types: $(slurm_tools_gpu_types_help)"
  echo ""
  echo "Environment: SLURM_TOOLS_ALLOC_SCRIPT, SLURM_TOOLS_MIG_PARTITION,"
  echo "  SLURM_TOOLS_SKIP_UPGRADE, SLURM_TOOLS_FORCE_UPGRADE_CHECK"
  echo ""
  echo "Options:"
  echo "  -j JOB_NAME        Job name (default: derived)"
  echo "  -n NODES           Number of nodes (default: 1)"
  echo "  -c CPU_CORE        CPU cores per node (default: 16)"
  echo "  -m MEM_GB          Memory per node in GB (default: 256)"
  echo "  -u GPU_TYPE        GPU type (default: any GPU type)"
  echo "  -g GPU_COUNT       GPUs per node (default: 1)"
  echo "  -t TIMEOUT_HOURS   Timeout in hours (default: 12)"
  echo "  -p PARTITION       Partition (default: best)"
  echo "  -v                 Show version"
  echo "  -h                 Show this help message"
  exit 1
}

on_interrupt() {
  echo "Ctrl+C pressed, cancelling job..."
  if [[ -n "${job_id:-}" ]]; then
    scancel "$job_id" 2>/dev/null || true
  fi
  exit 1
}

slurm_tools_maybe_auto_upgrade "$@"

JOB_NAME=""
NODE_COUNT=1
CPU_CORE=16
MEM_GB=256
GPU_TYPE=""
GPU_COUNT=1
TIMEOUT_HOURS=12
PARTITION="best"

while getopts "vhj:n:c:m:g:u:t:p:" opt; do
  case $opt in
    j) JOB_NAME="$OPTARG" ;;
    n) NODE_COUNT="$OPTARG" ;;
    c) CPU_CORE="$OPTARG" ;;
    m) MEM_GB="$OPTARG" ;;
    u) GPU_TYPE="$OPTARG" ;;
    g) GPU_COUNT="$OPTARG" ;;
    t) TIMEOUT_HOURS="$OPTARG" ;;
    p) PARTITION="$OPTARG" ;;
    v) echo "version: ${SLURM_TOOLS_VERSION}" && exit 0 ;;
    h) usage ;;
    \?) echo "Invalid option -$OPTARG" >&2; usage ;;
  esac
done

trap on_interrupt INT

if [[ -z "${JOB_NAME}" ]]; then
  JOB_NAME="$(slurm_tools_default_job_name "$GPU_COUNT" "$GPU_TYPE")"
fi

PARTITION_WAS_BEST=0
[[ "${PARTITION}" == "best" ]] && PARTITION_WAS_BEST=1
PARTITION="$(slurm_tools_resolve_partition "$PARTITION" "$CPU_CORE" "$MEM_GB" "$GPU_COUNT" "$GPU_TYPE" "$TIMEOUT_HOURS" "$NODE_COUNT")" || true
if [[ -z "${PARTITION}" ]]; then
  slurm_tools_print_log "No suitable partitions found for your requirements."
  exit 1
fi
if [[ "$PARTITION_WAS_BEST" -eq 1 ]]; then
  slurm_tools_print_log "best partition: ${PARTITION}"
fi

slurm_tools_print_log "parameters: JOB_NAME=${JOB_NAME}, NODES=${NODE_COUNT}, CPU_CORE=${CPU_CORE}, MEM_GB=${MEM_GB}, GPU_TYPE=${GPU_TYPE:-any}, GPU_COUNT=${GPU_COUNT}, TIMEOUT_HOURS=${TIMEOUT_HOURS}, PARTITION=${PARTITION}"

TIMEOUT_STRING="$(slurm_tools_timeout_string "$TIMEOUT_HOURS")"

if ! slurm_tools_build_gres_args "$GPU_TYPE" "$GPU_COUNT"; then
  slurm_tools_print_log "Invalid GPU type: ${GPU_TYPE}"
  exit 1
fi

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
