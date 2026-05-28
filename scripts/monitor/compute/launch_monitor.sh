#!/usr/bin/env bash
# Launch and control compute_monitor.sh across Slurm allocations.
# Usage:
#   launch_monitor.sh allocate -- submit dedicated monitor jobs for one or more partitions
#   launch_monitor.sh start    -- start a monitor task on every node in an existing allocation
#   launch_monitor.sh stop     -- stop one monitor job or all tracked monitor allocations
#   launch_monitor.sh status   -- report one monitor job or all tracked monitor allocations
#   launch_monitor.sh once     -- take one snapshot on every node in an existing allocation
#   launch_monitor.sh tail     -- tail logs for one monitor job or all tracked monitor allocations

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/compute_monitor.sh"
OUTPUT_DIR="${COMPUTE_MONITOR_OUTPUT_DIR:-${SCRIPT_DIR}/logs}"
PID_DIR="${COMPUTE_MONITOR_PID_DIR:-${HOME}/.run}"
INTERVAL="${COMPUTE_MONITOR_INTERVAL:-60}"
PARTITION_SPEC="${COMPUTE_MONITOR_PARTITION:-}"
ACCOUNT="${COMPUTE_MONITOR_ACCOUNT:-}"
QOS="${COMPUTE_MONITOR_QOS:-}"
TIME_LIMIT="${COMPUTE_MONITOR_TIME:-00:30:00}"
CONSTRAINT="${COMPUTE_MONITOR_CONSTRAINT:-}"
RESERVATION="${COMPUTE_MONITOR_RESERVATION:-}"
EXCLUDE="${COMPUTE_MONITOR_EXCLUDE:-}"
EXCLUDE_PARTITIONS="${COMPUTE_MONITOR_EXCLUDE_PARTITIONS:-}"
STATE_FILE="${COMPUTE_MONITOR_STATE_FILE:-${PID_DIR}/compute_monitor_jobs.tsv}"
ALLOCATE_NODELIST="${COMPUTE_MONITOR_ALLOCATE_NODELIST:-}"
ALLOC_JOB_NAME_PREFIX="${COMPUTE_MONITOR_ALLOC_JOB_NAME_PREFIX:-compute-monitor-alloc}"
BIGMEM_MIN_MEMORY="${COMPUTE_MONITOR_BIGMEM_MIN_MEMORY:-1001G}"
GPU_PER_NODE="${COMPUTE_MONITOR_GPUS_PER_NODE:-1}"

JOB_ID=""
NNODES=0
NODELIST_CSV=""
declare -a MONITOR_NODES=()

declare -a STATE_JOB_IDS=()
declare -a STATE_PARTITIONS=()
declare -a STATE_NODE_COUNTS=()
declare -a STATE_NODELISTS=()
declare -a STATE_SUBMITTED_ATS=()

declare -a TARGET_PARTITIONS=()

_job_root() {
    local job_id="$1"
    printf '%s/job_%s' "$OUTPUT_DIR" "$job_id"
}

_ensure_state_dir() {
    mkdir -p "$(dirname "$STATE_FILE")"
}

_pid_file_for_node() {
    local job_id="$1" node="$2"
    printf '%s/compute_monitor_%s_%s.pid' "$PID_DIR" "$job_id" "$node"
}

_pid_field() {
    local key="$1" pid_file="$2"
    awk -F= -v wanted="$key" '$1 == wanted { print $2; exit }' "$pid_file" 2>/dev/null || true
}

_reset_state_arrays() {
    STATE_JOB_IDS=()
    STATE_PARTITIONS=()
    STATE_NODE_COUNTS=()
    STATE_NODELISTS=()
    STATE_SUBMITTED_ATS=()
}

_append_state_record() {
    local job_id="$1" partition="$2" node_count="$3" nodes_csv="$4" submitted_at="$5"
    STATE_JOB_IDS+=("$job_id")
    STATE_PARTITIONS+=("$partition")
    STATE_NODE_COUNTS+=("$node_count")
    STATE_NODELISTS+=("$nodes_csv")
    STATE_SUBMITTED_ATS+=("$submitted_at")
}

_load_state_records() {
    _reset_state_arrays
    if [[ ! -f "$STATE_FILE" ]]; then
        return 0
    fi

    local job_id partition node_count nodes_csv submitted_at
    while IFS='|' read -r job_id partition node_count nodes_csv submitted_at; do
        if [[ -z "$job_id" || "$job_id" == \#* ]]; then
            continue
        fi
        _append_state_record "$job_id" "$partition" "$node_count" "$nodes_csv" "$submitted_at"
    done < "$STATE_FILE"
}

_save_state_records() {
    if [[ "${#STATE_JOB_IDS[@]}" -eq 0 ]]; then
        rm -f "$STATE_FILE"
        return 0
    fi

    _ensure_state_dir
    {
        printf '# job_id|partition|node_count|nodes_csv|submitted_at\n'
        local idx
        for idx in "${!STATE_JOB_IDS[@]}"; do
            printf '%s|%s|%s|%s|%s\n' \
                "${STATE_JOB_IDS[$idx]}" \
                "${STATE_PARTITIONS[$idx]}" \
                "${STATE_NODE_COUNTS[$idx]}" \
                "${STATE_NODELISTS[$idx]}" \
                "${STATE_SUBMITTED_ATS[$idx]}"
        done
    } > "$STATE_FILE"
}

_remove_state_job_id() {
    local remove_job_id="$1"
    _load_state_records

    local keep_job_ids=() keep_partitions=() keep_node_counts=() keep_nodelists=() keep_submitted_ats=()
    local idx
    for idx in "${!STATE_JOB_IDS[@]}"; do
        if [[ "${STATE_JOB_IDS[$idx]}" == "$remove_job_id" ]]; then
            continue
        fi
        keep_job_ids+=("${STATE_JOB_IDS[$idx]}")
        keep_partitions+=("${STATE_PARTITIONS[$idx]}")
        keep_node_counts+=("${STATE_NODE_COUNTS[$idx]}")
        keep_nodelists+=("${STATE_NODELISTS[$idx]}")
        keep_submitted_ats+=("${STATE_SUBMITTED_ATS[$idx]}")
    done

    STATE_JOB_IDS=("${keep_job_ids[@]}")
    STATE_PARTITIONS=("${keep_partitions[@]}")
    STATE_NODE_COUNTS=("${keep_node_counts[@]}")
    STATE_NODELISTS=("${keep_nodelists[@]}")
    STATE_SUBMITTED_ATS=("${keep_submitted_ats[@]}")
    _save_state_records
}

_job_info_for() {
    local job_id="$1"
    squeue -j "$job_id" -h -o "%T|%R|%P|%D|%N|%j" | head -n 1 || true
}

_job_exists_for() {
    local job_id="$1"
    [[ -n "$(_job_info_for "$job_id")" ]]
}

_job_state_for() {
    local job_id="$1" info
    info="$(_job_info_for "$job_id")"
    printf '%s\n' "${info%%|*}"
}

_job_name_for() {
    local job_id="$1" info
    info="$(_job_info_for "$job_id")"
    printf '%s\n' "${info##*|}"
}

_job_summary_for() {
    local job_id="$1" info state reason partition nodes nodelist name rest
    info="$(_job_info_for "$job_id")"
    if [[ -z "$info" ]]; then
        return 1
    fi

    state="${info%%|*}"
    rest="${info#*|}"
    reason="${rest%%|*}"
    rest="${rest#*|}"
    partition="${rest%%|*}"
    rest="${rest#*|}"
    nodes="${rest%%|*}"
    rest="${rest#*|}"
    nodelist="${rest%%|*}"
    name="${rest##*|}"

    printf 'job %s: state=%s partition=%s nodes=%s reason=%s name=%s nodelist=%s\n' \
        "$job_id" "$state" "$partition" "$nodes" "$reason" "$name" "$nodelist"
}

_prune_state_records() {
    _load_state_records

    local live_job_ids=() live_partitions=() live_node_counts=() live_nodelists=() live_submitted_ats=()
    local idx
    for idx in "${!STATE_JOB_IDS[@]}"; do
        if _job_exists_for "${STATE_JOB_IDS[$idx]}"; then
            live_job_ids+=("${STATE_JOB_IDS[$idx]}")
            live_partitions+=("${STATE_PARTITIONS[$idx]}")
            live_node_counts+=("${STATE_NODE_COUNTS[$idx]}")
            live_nodelists+=("${STATE_NODELISTS[$idx]}")
            live_submitted_ats+=("${STATE_SUBMITTED_ATS[$idx]}")
        fi
    done

    STATE_JOB_IDS=("${live_job_ids[@]}")
    STATE_PARTITIONS=("${live_partitions[@]}")
    STATE_NODE_COUNTS=("${live_node_counts[@]}")
    STATE_NODELISTS=("${live_nodelists[@]}")
    STATE_SUBMITTED_ATS=("${live_submitted_ats[@]}")
    _save_state_records
}

_count_state_records() {
    printf '%s\n' "${#STATE_JOB_IDS[@]}"
}

_find_state_index_by_partition() {
    local wanted="$1" idx
    for idx in "${!STATE_PARTITIONS[@]}"; do
        if [[ "${STATE_PARTITIONS[$idx]}" == "$wanted" ]]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done
    return 1
}

_find_state_index_by_job_id() {
    local wanted="$1" idx
    for idx in "${!STATE_JOB_IDS[@]}"; do
        if [[ "${STATE_JOB_IDS[$idx]}" == "$wanted" ]]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done
    return 1
}

_normalize_partition_name() {
    local partition="$1"
    partition="${partition%\*}"
    printf '%s\n' "$partition"
}

_contains_partition() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

_list_visible_partitions() {
    sinfo -h -o "%P" | while IFS= read -r partition; do
        partition="$(_normalize_partition_name "$partition")"
        if [[ -n "$partition" ]]; then
            printf '%s\n' "$partition"
        fi
    done | sort -u
}

_resolve_target_partitions() {
    if [[ -z "$PARTITION_SPEC" ]]; then
        printf 'compute monitor: set COMPUTE_MONITOR_PARTITION to a partition name, a comma-separated list, or all.\n' >&2
        exit 1
    fi

    local requested=()
    if [[ "$PARTITION_SPEC" == "all" ]]; then
        mapfile -t requested < <(_list_visible_partitions)
    else
        local raw="${PARTITION_SPEC//,/ }"
        read -r -a requested <<< "$raw"
    fi

    if [[ "${#requested[@]}" -eq 0 ]]; then
        printf 'compute monitor: no partitions resolved from %s.\n' "$PARTITION_SPEC" >&2
        exit 1
    fi

    local excluded=()
    if [[ -n "$EXCLUDE_PARTITIONS" ]]; then
        local raw_excluded="${EXCLUDE_PARTITIONS//,/ }"
        read -r -a excluded <<< "$raw_excluded"
    fi

    TARGET_PARTITIONS=()
    local partition normalized
    for partition in "${requested[@]}"; do
        normalized="$(_normalize_partition_name "$partition")"
        if [[ -z "$normalized" ]]; then
            continue
        fi
        if _contains_partition "$normalized" "${excluded[@]}"; then
            continue
        fi
        if ! _contains_partition "$normalized" "${TARGET_PARTITIONS[@]}"; then
            TARGET_PARTITIONS+=("$normalized")
        fi
    done

    if [[ "${#TARGET_PARTITIONS[@]}" -eq 0 ]]; then
        printf 'compute monitor: all requested partitions were filtered out.\n' >&2
        exit 1
    fi

    if [[ "${#TARGET_PARTITIONS[@]}" -gt 1 && -n "$ALLOCATE_NODELIST" ]]; then
        printf 'compute monitor: COMPUTE_MONITOR_ALLOCATE_NODELIST only works with a single partition.\n' >&2
        exit 1
    fi
}

_resolve_job_id() {
    if [[ -n "${COMPUTE_MONITOR_JOB_ID:-}" ]]; then
        JOB_ID="${COMPUTE_MONITOR_JOB_ID}"
        return 0
    fi
    if [[ -n "${SLURM_JOB_ID:-}" ]]; then
        JOB_ID="${SLURM_JOB_ID}"
        return 0
    fi

    _prune_state_records
    _load_state_records
    if [[ "${#STATE_JOB_IDS[@]}" -eq 1 ]]; then
        JOB_ID="${STATE_JOB_IDS[0]}"
        return 0
    fi
    if [[ "${#STATE_JOB_IDS[@]}" -gt 1 ]]; then
        printf 'compute monitor: multiple tracked monitor jobs exist; set COMPUTE_MONITOR_JOB_ID.\n' >&2
        exit 1
    fi

    local jobs=()
    mapfile -t jobs < <(squeue -u "${USER}" -h -t RUNNING -o "%i")
    if [[ "${#jobs[@]}" -eq 1 ]]; then
        JOB_ID="${jobs[0]}"
        return 0
    fi
    if [[ "${#jobs[@]}" -eq 0 ]]; then
        printf 'compute monitor: no active Slurm job found; set COMPUTE_MONITOR_JOB_ID or use allocate.\n' >&2
        exit 1
    fi

    printf 'compute monitor: multiple running Slurm jobs found; set COMPUTE_MONITOR_JOB_ID.\n' >&2
    exit 1
}

_contains_node() {
    local needle="$1"
    shift
    local node
    for node in "$@"; do
        if [[ "$node" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

_require_running_job() {
    _resolve_job_id
    if ! _job_exists_for "$JOB_ID"; then
        printf 'compute monitor: job %s not found.\n' "$JOB_ID" >&2
        exit 1
    fi
    local state
    state="$(_job_state_for "$JOB_ID")"
    if [[ "$state" != "RUNNING" ]]; then
        printf 'compute monitor: job %s is not RUNNING (state=%s).\n' "$JOB_ID" "${state:-unknown}" >&2
        exit 1
    fi
}

_load_nodes() {
    local job_nodes=()
    mapfile -t job_nodes < <(
        scontrol show hostnames "$(squeue -j "${JOB_ID}" -h -o "%N")"
    )
    if [[ "${#job_nodes[@]}" -eq 0 ]]; then
        printf 'compute monitor: failed to resolve nodes for job %s.\n' "$JOB_ID" >&2
        exit 1
    fi

    MONITOR_NODES=()
    if [[ -n "${COMPUTE_MONITOR_NODES:-}" ]]; then
        read -r -a MONITOR_NODES <<< "${COMPUTE_MONITOR_NODES}"
        local node
        for node in "${MONITOR_NODES[@]}"; do
            if ! _contains_node "$node" "${job_nodes[@]}"; then
                printf 'compute monitor: node %s is not part of job %s.\n' "$node" "$JOB_ID" >&2
                exit 1
            fi
        done
    else
        MONITOR_NODES=("${job_nodes[@]}")
    fi

    NNODES="${#MONITOR_NODES[@]}"
    NODELIST_CSV="$(IFS=,; printf '%s' "${MONITOR_NODES[*]}")"
}

_run_on_nodes() {
    local cmd="$1"
    COMPUTE_MONITOR_JOB_ID="${JOB_ID}" \
    COMPUTE_MONITOR_OUTPUT_DIR="${OUTPUT_DIR}" \
    COMPUTE_MONITOR_PID_DIR="${PID_DIR}" \
    COMPUTE_MONITOR_INTERVAL="${INTERVAL}" \
    srun --overlap --jobid="${JOB_ID}" \
        -N "${NNODES}" -n "${NNODES}" --ntasks-per-node=1 \
        -w "${NODELIST_CSV}" \
        bash "${MONITOR_SCRIPT}" "${cmd}"
}

_find_step_id() {
    local node pid_file step_id
    for node in "${MONITOR_NODES[@]}"; do
        pid_file="$(_pid_file_for_node "$JOB_ID" "$node")"
        if [[ -f "$pid_file" ]]; then
            step_id="$(_pid_field step_id "$pid_file")"
            if [[ -n "$step_id" ]]; then
                printf '%s\n' "$step_id"
                return 0
            fi
        fi
    done
    return 1
}

_clear_pid_files() {
    local job_id="$1"
    if [[ -d "$PID_DIR" ]]; then
        find "$PID_DIR" -maxdepth 1 -type f -name "compute_monitor_${job_id}_*.pid" -delete 2>/dev/null || true
    fi
}

_load_allocation_nodes_for_partition() {
    local partition="$1"
    local nodes=()

    if [[ -n "$ALLOCATE_NODELIST" ]]; then
        mapfile -t nodes < <(scontrol show hostnames "$ALLOCATE_NODELIST")
    else
        mapfile -t nodes < <(
            sinfo -h -N -p "$partition" -o "%N|%T" \
                | awk -F'|' '
                    {
                        state=tolower($2)
                        gsub(/[^a-z]/, "", state)
                        if (state == "idle" || state == "mixed" || state == "allocated" || state == "completing")
                            print $1
                    }
                ' \
                | sort -u
        )
    fi

    if [[ "${#nodes[@]}" -eq 0 ]]; then
        return 1
    fi

    MONITOR_NODES=("${nodes[@]}")
    NNODES="${#MONITOR_NODES[@]}"
    NODELIST_CSV="$(IFS=,; printf '%s' "${MONITOR_NODES[*]}")"
    return 0
}

_partition_requires_gpu() {
    local partition="$1"
    [[ "$partition" == *gpu* ]]
}

_partition_requires_bigmem_min_mem() {
    local partition="$1"
    [[ "$partition" == bigmem* ]]
}

_partition_time_limit() {
    local partition="$1"
    if [[ -n "${COMPUTE_MONITOR_TIME:-}" ]]; then
        printf '%s\n' "${COMPUTE_MONITOR_TIME}"
        return 0
    fi

    case "$partition" in
        bigmem_intermediate|intermediate)
            printf '3-00:01:00\n'
            ;;
        *)
            printf '%s\n' "$TIME_LIMIT"
            ;;
    esac
}

_submit_allocation_job() {
    local partition="$1"
    local nodes_csv="$2"
    local node_count="$3"
    local job_name="${ALLOC_JOB_NAME_PREFIX}-${partition}"

    mkdir -p "$OUTPUT_DIR" "$PID_DIR"

    local batch_file
    batch_file="$(mktemp)"
    cat > "$batch_file" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export COMPUTE_MONITOR_JOB_ID="\${SLURM_JOB_ID}"
export COMPUTE_MONITOR_OUTPUT_DIR='${OUTPUT_DIR}'
export COMPUTE_MONITOR_PID_DIR='${PID_DIR}'
export COMPUTE_MONITOR_INTERVAL='${INTERVAL}'
mkdir -p '${OUTPUT_DIR}' '${PID_DIR}'
srun --ntasks="\${SLURM_JOB_NUM_NODES}" --nodes="\${SLURM_JOB_NUM_NODES}" --ntasks-per-node=1 -w '${nodes_csv}' bash '${MONITOR_SCRIPT}' _daemon_internal
EOF
    chmod +x "$batch_file"

    local partition_time
    partition_time="$(_partition_time_limit "$partition")"

    local cmd=(
        sbatch
        --parsable
        --job-name="${job_name}"
        --partition="${partition}"
        --nodes="${node_count}"
        --ntasks="${node_count}"
        --ntasks-per-node=1
        --exclusive
        --nodelist="${nodes_csv}"
        --time="${partition_time}"
        --output="${OUTPUT_DIR}/alloc_%j.out"
        --error="${OUTPUT_DIR}/alloc_%j.err"
    )

    if [[ -n "$ACCOUNT" ]]; then
        cmd+=(--account="${ACCOUNT}")
    fi
    if [[ -n "$QOS" ]]; then
        cmd+=(--qos="${QOS}")
    fi
    if [[ -n "$CONSTRAINT" ]]; then
        cmd+=(--constraint="${CONSTRAINT}")
    fi
    if [[ -n "$RESERVATION" ]]; then
        cmd+=(--reservation="${RESERVATION}")
    fi
    if [[ -n "$EXCLUDE" ]]; then
        cmd+=(--exclude="${EXCLUDE}")
    fi
    if _partition_requires_gpu "$partition"; then
        cmd+=(--gpus-per-node="${GPU_PER_NODE}")
    fi
    if _partition_requires_bigmem_min_mem "$partition"; then
        cmd+=(--mem="${BIGMEM_MIN_MEMORY}")
    fi
    cmd+=("$batch_file")

    local submit_output
    if ! submit_output="$("${cmd[@]}" 2>&1)"; then
        rm -f "$batch_file"
        printf 'compute monitor: sbatch failed for partition %s: %s\n' "$partition" "$submit_output" >&2
        return 1
    fi
    rm -f "$batch_file"

    JOB_ID="${submit_output%%;*}"
    if [[ -z "$JOB_ID" ]]; then
        printf 'compute monitor: failed to parse sbatch output for partition %s: %s\n' "$partition" "$submit_output" >&2
        return 1
    fi

    return 0
}

_status_one_job() {
    local job_id="$1"
    JOB_ID="$job_id"

    if ! _job_exists_for "$JOB_ID"; then
        printf 'compute monitor: job %s not found.\n' "$JOB_ID"
        return 1
    fi

    _job_summary_for "$JOB_ID"

    local state
    state="$(_job_state_for "$JOB_ID")"
    if [[ "$state" != "RUNNING" ]]; then
        return 0
    fi

    _load_nodes
    local step_id status_output
    step_id="$(_find_step_id || true)"
    if [[ -n "$step_id" ]]; then
        printf 'monitor step: %s.%s\n' "$JOB_ID" "$step_id"
    else
        printf 'monitor step: not yet discovered from pid files\n'
    fi

    status_output="$(_run_on_nodes status_once 2>&1 || true)"
    printf '%s\n' "$status_output"
}

_stop_one_job() {
    local job_id="$1"
    JOB_ID="$job_id"

    if ! _job_exists_for "$JOB_ID"; then
        _clear_pid_files "$JOB_ID"
        _remove_state_job_id "$JOB_ID"
        printf 'compute monitor: job %s not found; cleared local state.\n' "$JOB_ID"
        return 0
    fi

    local state job_name
    state="$(_job_state_for "$JOB_ID")"
    job_name="$(_job_name_for "$JOB_ID")"

    if [[ "$job_name" == "${ALLOC_JOB_NAME_PREFIX}-"* ]]; then
        scancel "$JOB_ID" >/dev/null 2>&1 || true
        _clear_pid_files "$JOB_ID"
        _remove_state_job_id "$JOB_ID"
        printf 'compute monitor allocation cancelled for job %s\n' "$JOB_ID"
        return 0
    fi

    if [[ "$state" == "RUNNING" ]]; then
        _load_nodes
        local step_id
        step_id="$(_find_step_id || true)"
        if [[ -n "$step_id" ]]; then
            scancel "${JOB_ID}.${step_id}" >/dev/null 2>&1 || true
            sleep 2
        fi
        _run_on_nodes stop_local >/dev/null 2>&1 || true
    fi

    _clear_pid_files "$JOB_ID"
    _remove_state_job_id "$JOB_ID"
    printf 'compute monitor stopped for job %s\n' "$JOB_ID"
}

_tail_one_job() {
    local job_id="$1"
    local day dir
    day="$(date +%Y-%m-%d)"
    dir="$(_job_root "$job_id")/${day}"
    if [[ ! -d "$dir" ]]; then
        printf 'compute monitor: no logs found in %s\n' "$dir" >&2
        return 1
    fi

    local files=()
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name "*.log" | sort)
    if [[ "${#files[@]}" -eq 0 ]]; then
        printf 'compute monitor: no log files found in %s\n' "$dir" >&2
        return 1
    fi

    printf '=== logs for job %s ===\n' "$job_id"
    tail -n 80 "${files[@]}"
}

cmd_allocate() {
    _resolve_target_partitions
    _prune_state_records
    _load_state_records

    local submitted=0 skipped=0 failed=0
    local partition idx submitted_at
    for partition in "${TARGET_PARTITIONS[@]}"; do
        if idx="$(_find_state_index_by_partition "$partition" 2>/dev/null)"; then
            if _job_exists_for "${STATE_JOB_IDS[$idx]}"; then
                printf 'compute monitor: partition %s already tracked by job %s; skipping.\n' \
                    "$partition" "${STATE_JOB_IDS[$idx]}"
                skipped=$((skipped + 1))
                continue
            fi
        fi

        if ! _load_allocation_nodes_for_partition "$partition"; then
            printf 'compute monitor: no allocatable nodes found in partition %s; skipping.\n' "$partition" >&2
            failed=$((failed + 1))
            continue
        fi

        local nodes_csv="$NODELIST_CSV"
        local node_count="$NNODES"
        if ! _submit_allocation_job "$partition" "$nodes_csv" "$node_count"; then
            failed=$((failed + 1))
            continue
        fi

        submitted_at="$(date -Is)"
        _append_state_record "$JOB_ID" "$partition" "$node_count" "$nodes_csv" "$submitted_at"
        printf 'compute monitor allocation submitted: partition=%s job=%s nodes=%s\n' \
            "$partition" "$JOB_ID" "$node_count"
        submitted=$((submitted + 1))
    done

    _save_state_records

    printf 'compute monitor allocation summary: submitted=%s skipped=%s failed=%s\n' \
        "$submitted" "$skipped" "$failed"
    if [[ "$submitted" -eq 0 && "$failed" -gt 0 ]]; then
        exit 1
    fi
}

cmd_start() {
    _require_running_job
    _load_nodes

    local status_output
    status_output="$(_run_on_nodes status_once 2>&1 || true)"
    if grep -q 'RUNNING' <<< "$status_output"; then
        printf 'compute monitor already running for job %s\n' "$JOB_ID"
        printf '%s\n' "$status_output"
        return 0
    fi

    _clear_pid_files "$JOB_ID"
    mkdir -p "$(_job_root "$JOB_ID")" "$PID_DIR"

    local launch_log
    launch_log="$(_job_root "$JOB_ID")/launch_$(date +%Y%m%d_%H%M%S).nohup.log"

    COMPUTE_MONITOR_JOB_ID="${JOB_ID}" \
    COMPUTE_MONITOR_OUTPUT_DIR="${OUTPUT_DIR}" \
    COMPUTE_MONITOR_PID_DIR="${PID_DIR}" \
    COMPUTE_MONITOR_INTERVAL="${INTERVAL}" \
    nohup srun --overlap --jobid="${JOB_ID}" \
        --job-name="compute-monitor-${JOB_ID}" \
        -N "${NNODES}" -n "${NNODES}" --ntasks-per-node=1 \
        -w "${NODELIST_CSV}" \
        bash "${MONITOR_SCRIPT}" _daemon_internal \
        > "${launch_log}" 2>&1 &

    local attempt ready
    ready=0
    for attempt in {1..10}; do
        sleep 1
        status_output="$(_run_on_nodes status_once 2>&1 || true)"
        if grep -q 'RUNNING' <<< "$status_output"; then
            ready=1
            break
        fi
    done

    printf 'compute monitor launched for job %s on nodes: %s\n' "$JOB_ID" "$NODELIST_CSV"
    printf 'launch log: %s\n' "$launch_log"
    if [[ "$ready" -eq 1 ]]; then
        local step_id
        step_id="$(_find_step_id || true)"
        if [[ -n "$step_id" ]]; then
            printf 'step id: %s.%s\n' "$JOB_ID" "$step_id"
        fi
        printf '%s\n' "$status_output"
    else
        printf 'monitor step did not report ready within 10 seconds; check the launch log.\n'
    fi
}

cmd_stop() {
    if [[ -n "${COMPUTE_MONITOR_JOB_ID:-}" || -n "${SLURM_JOB_ID:-}" ]]; then
        _resolve_job_id
        _stop_one_job "$JOB_ID"
        return 0
    fi

    _prune_state_records
    _load_state_records
    if [[ "${#STATE_JOB_IDS[@]}" -gt 0 ]]; then
        local job_ids=("${STATE_JOB_IDS[@]}")
        local job_id
        for job_id in "${job_ids[@]}"; do
            _stop_one_job "$job_id"
        done
        return 0
    fi

    _resolve_job_id
    _stop_one_job "$JOB_ID"
}

cmd_status() {
    if [[ -n "${COMPUTE_MONITOR_JOB_ID:-}" || -n "${SLURM_JOB_ID:-}" ]]; then
        _resolve_job_id
        _status_one_job "$JOB_ID"
        return 0
    fi

    _prune_state_records
    _load_state_records
    if [[ "${#STATE_JOB_IDS[@]}" -gt 0 ]]; then
        local job_id
        for job_id in "${STATE_JOB_IDS[@]}"; do
            _status_one_job "$job_id"
        done
        return 0
    fi

    _resolve_job_id
    _status_one_job "$JOB_ID"
}

cmd_once() {
    _require_running_job
    _load_nodes

    printf 'taking one compute snapshot for job %s on nodes: %s\n' "$JOB_ID" "$NODELIST_CSV"
    _run_on_nodes once
}

cmd_tail() {
    if [[ -n "${COMPUTE_MONITOR_JOB_ID:-}" || -n "${SLURM_JOB_ID:-}" ]]; then
        _resolve_job_id
        _tail_one_job "$JOB_ID"
        return 0
    fi

    _prune_state_records
    _load_state_records
    if [[ "${#STATE_JOB_IDS[@]}" -gt 0 ]]; then
        local job_id
        for job_id in "${STATE_JOB_IDS[@]}"; do
            _tail_one_job "$job_id" || true
        done
        return 0
    fi

    _resolve_job_id
    _tail_one_job "$JOB_ID"
}

case "${1:-}" in
    allocate) cmd_allocate ;;
    start)    cmd_start ;;
    stop)     cmd_stop ;;
    status)   cmd_status ;;
    once)     cmd_once ;;
    tail)     cmd_tail ;;
    *)
        printf 'Usage: %s {allocate|start|stop|status|once|tail}\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac
