# Shared helpers for slurm-alloc / slurm-submit. Source from repo scripts only.
# Site overrides (optional):
#   SLURM_TOOLS_ALLOC_SCRIPT      Batch script for slurm-alloc placeholder job
#   SLURM_TOOLS_MIG_PARTITION     Partition for a100mig (default: gpu_test)
#   SLURM_TOOLS_SKIP_UPGRADE      Set to 1 to disable auto-upgrade
#   SLURM_TOOLS_FORCE_UPGRADE_CHECK  Set to 1 to force version check

slurm_tools_read_version() {
  local root="${SLURM_TOOLS_SCRIPT_DIR:-}"
  if [[ -f "${root}/VERSION" ]]; then
    tr -d '[:space:]' <"${root}/VERSION" | head -n1
  else
    printf "unknown"
  fi
}

slurm_tools_print_log() {
  printf '%s %s\n' "$(date +%Y-%m-%d\ %H:%M:%S)" "$*"
}

slurm_tools_wants_skip_upgrade() {
  [[ "${SLURM_TOOLS_SKIP_UPGRADE:-}" == "1" ]] && return 0
  local a
  for a in "$@"; do
    case "$a" in
      -v | -h | --help) return 0 ;;
    esac
  done
  return 1
}

slurm_tools_maybe_auto_upgrade() {
  local root="${SLURM_TOOLS_SCRIPT_DIR:-}" up rc cache_dir cache_file now last

  slurm_tools_wants_skip_upgrade "$@" && return 0

  up="${root}/upgrade.sh"
  [[ -f "$up" ]] || return 0

  cache_dir="${HOME}/.cache/slurm_tools"
  cache_file="${cache_dir}/last_version_check"
  now="$(date +%s)"
  if [[ "${SLURM_TOOLS_FORCE_UPGRADE_CHECK:-}" != "1" && -f "$cache_file" ]]; then
    last="$(tr -d '[:space:]' <"$cache_file")"
    if [[ -n "$last" && $((now - last)) -lt 86400 ]]; then
      return 0
    fi
  fi
  rc=0
  SLURM_TOOLS_ROOT="$root" bash "$up" --check --quiet || rc=$?
  if [[ "$rc" -eq 0 || "$rc" -eq 1 ]]; then
    mkdir -p "$cache_dir"
    printf '%s\n' "$now" >"$cache_file"
  fi
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 2 ]]; then
    slurm_tools_print_log "version check failed (offline?); continuing with ${SLURM_TOOLS_VERSION:-unknown}"
    return 0
  fi
  if [[ "$rc" -ne 1 ]]; then
    return 0
  fi

  slurm_tools_print_log "new slurm_tools release available; upgrading ${SLURM_TOOLS_VERSION:-unknown}..."
  if ! SLURM_TOOLS_ROOT="$root" bash "$up" -y --quiet; then
    slurm_tools_print_log "upgrade failed; continuing with ${SLURM_TOOLS_VERSION:-unknown}"
    return 0
  fi

  SLURM_TOOLS_VERSION="$(slurm_tools_read_version)"
  slurm_tools_print_log "upgraded to ${SLURM_TOOLS_VERSION}; restarting"
  exec "$0" "$@"
}

slurm_tools_timeout_string() {
  local hours="$1"
  if [[ "$hours" -gt 23 ]]; then
    printf '%d-%d:00:00' $((hours / 24)) $((hours % 24))
  else
    printf '%d:00:00' "$hours"
  fi
}

slurm_tools_default_job_name() {
  local gpu_count="$1" gpu_type="$2"
  if [[ "$gpu_count" -eq 0 ]]; then
    whoami
  else
    printf '%s%s' "$gpu_count" "${gpu_type:-gpu}"
  fi
}

# Map short GPU name to SLURM gres type; prints full name to stdout or returns 1.
slurm_tools_map_gpu_type() {
  case "$1" in
    h100) printf '%s' "nvidia_h100_80gb_hbm3" ;;
    h200) printf '%s' "nvidia_h200" ;;
    a100 | a100-80gb) printf '%s' "nvidia_a100-sxm4-80gb" ;;
    a100-40gb) printf '%s' "nvidia_a100-sxm4-40gb" ;;
    a40) printf '%s' "nvidia_a40" ;;
    a100mig) printf '%s' "nvidia_a100_3g.20gb" ;;
    *) return 1 ;;
  esac
}

slurm_tools_gpu_types_help() {
  printf '%s' "h100, h200, a100, a100-80gb, a100-40gb, a40, a100mig"
}

slurm_tools_build_gres_args() {
  local short_type="$1" count="$2" full
  GRES_ARGS=()
  [[ "$count" -gt 0 ]] || return 0
  # No GPU type given: request any GPU type.
  if [[ -z "$short_type" ]]; then
    GRES_ARGS=(--gres=gpu:"${count}")
    return 0
  fi
  if ! full="$(slurm_tools_map_gpu_type "$short_type")"; then
    return 1
  fi
  GRES_ARGS=(--gres=gpu:"${full}":"${count}")
}

slurm_tools_best_partition_cmd() {
  if command -v best-partition >/dev/null 2>&1; then
    printf '%s' "best-partition"
    return 0
  fi
  if command -v best_partition >/dev/null 2>&1; then
    printf '%s' "best_partition"
    return 0
  fi
  if [[ -n "${SLURM_TOOLS_SCRIPT_DIR:-}" && -x "${SLURM_TOOLS_SCRIPT_DIR}/best_partition.sh" ]]; then
    printf '%s' "${SLURM_TOOLS_SCRIPT_DIR}/best_partition.sh"
    return 0
  fi
  return 1
}

slurm_tools_resolve_partition() {
  # args: partition cpu mem gpu_count gpu_type timeout [node_count]
  local partition="$1" cpu="$2" mem="$3" gpu_count="$4" gpu_type="$5" timeout="$6"
  local nodes="${7:-1}"
  local mig_part="${SLURM_TOOLS_MIG_PARTITION:-gpu_test}"
  local best_partition_cmd

  [[ "$partition" != "best" ]] && { printf '%s' "$partition"; return 0; }

  if ! best_partition_cmd="$(slurm_tools_best_partition_cmd)"; then
    slurm_tools_print_log "best-partition command not found"
    return 1
  fi

  # Scale to total resources across all nodes so best-partition can filter correctly.
  local total_cpu=$(( cpu * nodes ))
  local total_mem=$(( mem * nodes ))
  local total_gpu=$(( gpu_count * nodes ))

  local bp_gpu_args=()
  if [[ "$total_gpu" -gt 0 ]]; then
    if [[ "$gpu_type" == "a100mig" ]]; then
      printf '%s' "$mig_part"
      return 0
    fi
    bp_gpu_args=(-g "$total_gpu")
    # Only constrain by type when one was given; empty means any GPU type.
    [[ -n "$gpu_type" ]] && bp_gpu_args+=(--gpu-type "$gpu_type")
  fi

  local result
  result="$("${best_partition_cmd}" -n -c "$total_cpu" -m "$total_mem" "${bp_gpu_args[@]}" -t "$timeout")"
  if [[ -n "$result" ]]; then
    printf '%s' "$result"
    return 0
  fi

  # No partition found using currently available resources; retry against total capacity.
  slurm_tools_print_log "warning: no partition has enough free resources right now; retrying against total capacity" >&2
  result="$("${best_partition_cmd}" -n --total-resources -c "$total_cpu" -m "$total_mem" "${bp_gpu_args[@]}" -t "$timeout")"
  if [[ -n "$result" ]]; then
    slurm_tools_print_log "warning: ${result} may be fully allocated; job will queue" >&2
    printf '%s' "$result"
    return 0
  fi
}

# Shared post-getopts preparation for slurm-alloc / slurm-submit.
# Reads the standard job vars as globals (JOB_NAME, NODE_COUNT, CPU_CORE,
# MEM_GB, GPU_TYPE, GPU_COUNT, TIMEOUT_HOURS, PARTITION); resolves a default
# job name and partition, logs the parameters, and sets TIMEOUT_STRING and the
# GRES_ARGS array. $1 is optional extra text appended to the parameters log
# (e.g. ", SCRIPT=foo"). Exits non-zero on unresolved partition / bad GPU type.
slurm_tools_prepare_job() {
  local extra="${1:-}" was_best=0

  if [[ -z "${JOB_NAME}" ]]; then
    JOB_NAME="$(slurm_tools_default_job_name "$GPU_COUNT" "$GPU_TYPE")"
  fi

  [[ "${PARTITION}" == "best" ]] && was_best=1
  PARTITION="$(slurm_tools_resolve_partition "$PARTITION" "$CPU_CORE" "$MEM_GB" "$GPU_COUNT" "$GPU_TYPE" "$TIMEOUT_HOURS" "$NODE_COUNT")" || true
  if [[ -z "${PARTITION}" ]]; then
    slurm_tools_print_log "No suitable partitions found for your requirements."
    exit 1
  fi
  [[ "$was_best" -eq 1 ]] && slurm_tools_print_log "best partition: ${PARTITION}"

  slurm_tools_print_log "parameters: JOB_NAME=${JOB_NAME}, NODES=${NODE_COUNT}, CPU_CORE=${CPU_CORE}, MEM_GB=${MEM_GB}, GPU_TYPE=${GPU_TYPE:-any}, GPU_COUNT=${GPU_COUNT}, TIMEOUT_HOURS=${TIMEOUT_HOURS}, PARTITION=${PARTITION}${extra}"

  TIMEOUT_STRING="$(slurm_tools_timeout_string "$TIMEOUT_HOURS")"

  if ! slurm_tools_build_gres_args "$GPU_TYPE" "$GPU_COUNT"; then
    slurm_tools_print_log "Invalid GPU type: ${GPU_TYPE}"
    exit 1
  fi
}

# Submit via sbatch; sets SLURM_TOOLS_JOB_ID on success.
slurm_tools_sbatch() {
  local out rc
  mkdir -p logs
  out="$(sbatch "$@" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  SLURM_TOOLS_JOB_ID="$(printf '%s' "$out" | awk '/Submitted batch job/ {print $4; exit}')"
  if [[ -z "${SLURM_TOOLS_JOB_ID:-}" ]]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}

slurm_tools_job_field() {
  local jid="$1" field="$2"
  scontrol show job -o "$jid" 2>/dev/null | awk -v key="${field}=" '
    {
      for (i = 1; i <= NF; i++) {
        if (index($i, key) == 1) {
          print substr($i, length(key) + 1)
          exit
        }
      }
    }
  '
}

slurm_tools_job_state() {
  local jid="$1"
  slurm_tools_job_field "$jid" "JobState"
}

slurm_tools_job_nodelist() {
  local jid="$1"
  slurm_tools_job_field "$jid" "NodeList"
}

# Wait until job is RUNNING with a valid NodeList, then record nodes.
# ~/.alloc/<job_name> receives the SLURM NodeList string (e.g. node[01-04]).
slurm_tools_wait_for_allocation() {
  local jid="$1" job_name="$2"
  local state nodelist first_node

  while true; do
    state="$(slurm_tools_job_state "$jid")"
    case "$state" in
      COMPLETED | FAILED | CANCELLED | TIMEOUT | NODE_FAIL | PREEMPTED | OUT_OF_MEMORY | BOOT_FAIL | DEADLINE)
        slurm_tools_print_log "job ${jid} ended with state ${state}"
        return 1
        ;;
      RUNNING | COMPLETING)
        nodelist="$(slurm_tools_job_nodelist "$jid")"
        # Derive first plain hostname to check validity.
        first_node="${nodelist%%,*}"
        first_node="${first_node%%\[*}"
        if [[ -n "$first_node" && "$first_node" != "(null)" && "$first_node" != "None" ]]; then
          slurm_tools_print_log "successfully allocated job_id ${jid} on ${nodelist}"
          mkdir -p "${HOME}/.alloc"
          printf '%s\n' "$nodelist" >"${HOME}/.alloc/${job_name}"
          return 0
        fi
        ;;
      "")
        if ! squeue -h -j "$jid" 2>/dev/null | grep -q .; then
          slurm_tools_print_log "job ${jid} no longer in queue (state unknown)"
          return 1
        fi
        ;;
    esac
    printf '.'
    sleep 5
  done
}

slurm_tools_alloc_script() {
  if [[ -n "${SLURM_TOOLS_ALLOC_SCRIPT:-}" ]]; then
    printf '%s' "$SLURM_TOOLS_ALLOC_SCRIPT"
    return 0
  fi
  printf '%s' "/n/holylabs/juncheng_lab/Lab/software/scripts/sleep.sh"
}

# Path to a generated placeholder script that sleeps for 7 days. Used by
# slurm-submit when no SCRIPT is given. Created on first use under the user
# cache dir so it persists at a stable absolute path while the job queues/runs.
slurm_tools_dummy_script() {
  local cache_dir="${HOME}/.cache/slurm_tools"
  local script="${cache_dir}/dummy_sleep.sh"
  if [[ ! -f "$script" ]]; then
    mkdir -p "$cache_dir"
    cat >"$script" <<'EOF'
#!/bin/bash
# Auto-generated placeholder by slurm-submit (no script provided).
# Holds the allocation by sleeping; Slurm kills it at the job time limit.
echo "slurm-submit placeholder: sleeping 7 days on $(hostname)"
sleep 7d
EOF
    chmod +x "$script"
  fi
  printf '%s' "$script"
}
