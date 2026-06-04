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

usage() {
  cat <<EOF
usage: ${PROG} [-J JOB_NAME] [-N NODES] [-c CPUS] [-m MEM_GB] [-G GPU_TYPE] [-g GPUS] [-t HOURS] [-p PARTITION] [SCRIPT [SCRIPT_ARGS...]]
default values: JOB_NAME derived, NODES=1, CPUS=16, MEM_GB=256, GPU_TYPE=any, GPUS=1, HOURS=12, PARTITION=best
if SCRIPT is omitted, a placeholder that sleeps 7 days is submitted
example: ${PROG} -N 2 -c 64 -m 512 -g 4 -G h200 -t 24 train.sh --config cfg.yaml
gpu types: $(slurm_tools_gpu_types_help)

Options:
  -J, --job-name NAME    Job name (default: derived from GPU count/type or username)
  -N, --nodes N          Number of nodes (default: 1)
  -c, --cpus N           CPU cores per node (default: 16)
  -m, --mem GB           Memory per node in GB (default: 256)
  -G, --gpu-type TYPE    GPU type (default: any GPU type)
  -g, --gpus N           GPUs per node (default: 1; use 0 for CPU-only)
  -t, --time HOURS       Wall time in hours (default: 12)
  -p, --partition NAME   Partition (default: best; auto-selects via 'st partition' logic)
  -x, --exclude LIST     Comma-separated partitions to exclude from auto-selection
      --version          Show version
  -h, --help             Show this help message
EOF
  exit 1
}

slurm_tools_set_job_defaults
slurm_tools_parse_job_args usage "$@"

USED_PLACEHOLDER=0
SCRIPT_ARGS=()
if [[ "${#SLURM_TOOLS_POSITIONAL[@]}" -eq 0 ]]; then
  SCRIPT="$(slurm_tools_dummy_script)"
  USED_PLACEHOLDER=1
  slurm_tools_print_log "no script provided; using placeholder that sleeps 7 days so you can log in to the node once it starts: ${SCRIPT}"
else
  SCRIPT="${SLURM_TOOLS_POSITIONAL[0]}"
  SCRIPT_ARGS=("${SLURM_TOOLS_POSITIONAL[@]:1}")
  if [[ ! -f "$SCRIPT" ]]; then
    slurm_tools_print_log "script not found: ${SCRIPT}"
    exit 1
  fi
fi

if [[ "$SCRIPT" == /* ]]; then
  SCRIPT_ABS="$SCRIPT"
else
  SCRIPT_ABS="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"
fi
SCRIPT_DIR_ABS="$(cd "$(dirname "$SCRIPT_ABS")" && pwd)"

slurm_tools_prepare_job ", SCRIPT=${SCRIPT}"

if ! slurm_tools_sbatch -p "${PARTITION}" \
  -J "${JOB_NAME}" \
  --nodes="${NODE_COUNT}" \
  --ntasks-per-node=1 \
  --mem="${MEM_GB}g" \
  --time="${TIMEOUT_STRING}" \
  -c "${CPU_CORE}" \
  --export="ALL,SLURM_TOOLS_SUBMIT_SCRIPT=${SCRIPT_ABS},SLURM_TOOLS_SUBMIT_SCRIPT_DIR=${SCRIPT_DIR_ABS}" \
  --mail-type=ALL \
  --output=logs/%x.%j.out \
  --error=logs/%x.%j.err \
  "${GRES_ARGS[@]}" \
  "$SCRIPT" "${SCRIPT_ARGS[@]}"; then
  slurm_tools_print_log "sbatch failed"
  exit 1
fi
slurm_tools_print_log "submitted job_id: ${SLURM_TOOLS_JOB_ID}"

if [[ "$USED_PLACEHOLDER" -eq 1 ]]; then
  slurm_tools_print_log "waiting for placeholder to start so it can report node hostnames (Ctrl+C stops waiting; the job keeps running)"
  printf '\n'
  if slurm_tools_wait_for_allocation "${SLURM_TOOLS_JOB_ID}" "${JOB_NAME}"; then
    printf '\n'
    NODELIST="$(slurm_tools_job_nodelist "${SLURM_TOOLS_JOB_ID}")"
    mapfile -t HOSTS < <(scontrol show hostnames "${NODELIST}" 2>/dev/null)
    slurm_tools_print_log "node hostnames: ${HOSTS[*]}"
    for h in "${HOSTS[@]}"; do
      slurm_tools_print_log "  ssh ${h}"
    done
    slurm_tools_print_log "or attach to the job with: srun --jobid ${SLURM_TOOLS_JOB_ID} --pty bash"
  else
    printf '\n'
    slurm_tools_print_log "placeholder ${SLURM_TOOLS_JOB_ID} not running yet; once RUNNING get hostnames with: scontrol show hostnames \$(squeue -h -j ${SLURM_TOOLS_JOB_ID} -o %N)"
  fi
fi
