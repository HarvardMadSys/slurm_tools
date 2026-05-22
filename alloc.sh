#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
  VERSION="$(tr -d '[:space:]' <"${SCRIPT_DIR}/VERSION" | head -n1)"
else
  VERSION="unknown"
fi

# default values
JOB_NAME=""
CPU_CORE=16
MEM_GB=256
GPU_TYPE="h100"
GPU_COUNT=1
TIMEOUT_HOURS=12
PARTITION="best"

usage(){
    echo "usage: $0 [-j JOB_NAME] [-c CPU_CORE] [-m MEM_GB] [-u GPU_TYPE] [-g GPU_COUNT] [-t TIMEOUT_HOURS] [-p PARTITION]"
    echo "default values: JOB_NAME=$(whoami), CPU_CORE=16, MEM_GB=256, GPU_TYPE=h100, GPU_COUNT=1, TIMEOUT_HOURS=12, PARTITION=best"
    echo "example: $0 -j $(whoami) -c 16 -m 256 -g 1 -u h100 -t 12 -p best"
    echo "gpu types: h100, h200, a100, a100-80gb, a100-40gb, a40, nvidia_a100_3g.20gb"
    echo ""
    echo "Options:"
    echo "  -j JOB_NAME        Job name (default: $(whoami))"
    echo "  -c CPU_CORE        Number of CPU cores (default: 16)"
    echo "  -m MEM_GB          Memory in GB (default: 256)"
    echo "  -u GPU_TYPE        GPU type (default: h100)"
    echo "  -g GPU_COUNT       Number of GPUs (default: 1)"
    echo "  -t TIMEOUT_HOURS   Timeout in hours (default: 12)"
    echo "  -p PARTITION       Partition (default: best)"
    echo "  -v                 Show version"
    echo "  -h                 Show this help message"
    exit 1
}

print_log() {
    echo $(date +%Y-%m-%d\ %H:%M:%S) $1
}

alloc_wants_skip_upgrade() {
    [[ "${SLURM_TOOLS_SKIP_UPGRADE:-}" == "1" ]] && return 0
    local a
    for a in "$@"; do
        case "$a" in
            -v | -h | --help) return 0 ;;
        esac
    done
    return 1
}

maybe_auto_upgrade() {
    local up rc cache_dir cache_file now last

    alloc_wants_skip_upgrade "$@" && return 0

    up="${SCRIPT_DIR}/upgrade.sh"
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
    SLURM_TOOLS_ROOT="$SCRIPT_DIR" bash "$up" --check --quiet || rc=$?
    if [[ "$rc" -eq 0 || "$rc" -eq 1 ]]; then
        mkdir -p "$cache_dir"
        printf '%s\n' "$now" >"$cache_file"
    fi
    if [[ "$rc" -eq 0 ]]; then
        return 0
    fi
    if [[ "$rc" -eq 2 ]]; then
        print_log "version check failed (offline?); continuing with ${VERSION}"
        return 0
    fi
    if [[ "$rc" -ne 1 ]]; then
        return 0
    fi

    print_log "new slurm_tools release available; upgrading ${VERSION}..."
    if ! SLURM_TOOLS_ROOT="$SCRIPT_DIR" bash "$up" -y --quiet; then
        print_log "upgrade failed; continuing with ${VERSION}"
        return 0
    fi

    if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
        VERSION="$(tr -d '[:space:]' <"${SCRIPT_DIR}/VERSION" | head -n1)"
    fi
    print_log "upgraded to ${VERSION}; restarting"
    exec "$0" "$@"
}

maybe_auto_upgrade "$@"

# cancel the job if user ctrl+c
trap 'echo "Ctrl+C pressed, cancelling job..."; scancel $job_id; exit 1' INT

# Parse command line arguments
# v/h must come before p: in the optstring (bash 3.2 treats p:v as "p:" + "v:" otherwise).
while getopts "vhj:c:m:g:u:t:p:" opt; do
    case $opt in
        j) JOB_NAME="$OPTARG" ;;
        c) CPU_CORE="$OPTARG" ;;
        m) MEM_GB="$OPTARG" ;;
        u) GPU_TYPE="$OPTARG" ;;
        g) GPU_COUNT="$OPTARG" ;;
        t) TIMEOUT_HOURS="$OPTARG" ;;
        p) PARTITION="$OPTARG" ;;
        v) echo "version: $VERSION" && exit 0 ;;
        h) usage ;;
        \?) echo "Invalid option -$OPTARG" >&2; usage ;;
    esac
done

# if JOB_NAME is not set, set it to the current user name
if [ -z "${JOB_NAME}" ]; then
    # if gpu count is 0, set JOB_NAME to the current user name
    if [ ${GPU_COUNT} -eq 0 ]; then
        JOB_NAME="$(whoami)"
    else
        JOB_NAME="${GPU_COUNT}${GPU_TYPE}"
    fi
fi

# if PARTITION is best, find the best partition
if [ "${PARTITION}" == "best" ]; then
    if [ ${GPU_COUNT} -gt 0 ]; then
        if [ "${GPU_TYPE}" == "a100mig" ]; then
            PARTITION="gpu_test"
        else
            PARTITION=$(best_partition -n -c ${CPU_CORE} -m ${MEM_GB} --gpu-type ${GPU_TYPE} -g ${GPU_COUNT} -t ${TIMEOUT_HOURS})
        fi
    else
        PARTITION=$(best_partition -n -c ${CPU_CORE} -m ${MEM_GB} -t ${TIMEOUT_HOURS})
    fi
    if [ -z "${PARTITION}" ]; then
        print_log "No suitable partitions found for your requirements."
        exit 1
    else 
        print_log "best partition: ${PARTITION}"
    fi
fi

# print parameters
print_log "parameters: JOB_NAME=${JOB_NAME}, CPU_CORE=${CPU_CORE}, MEM_GB=${MEM_GB}, GPU_TYPE=${GPU_TYPE}, GPU_COUNT=${GPU_COUNT}, TIMEOUT_HOURS=${TIMEOUT_HOURS}, PARTITION=${PARTITION}"

# if timeout_hours is more than 23, update the format
if [ ${TIMEOUT_HOURS} -gt 23 ]; then
    TIMEOUT_DAYS=$((${TIMEOUT_HOURS} / 24))
    TIMEOUT_HOURS=$((${TIMEOUT_HOURS} % 24))
    TIMEOUT_STRING="${TIMEOUT_DAYS}-${TIMEOUT_HOURS}:00:00"
else
    TIMEOUT_STRING="${TIMEOUT_HOURS}:00:00"
fi

GRES_ARGS=()
if [ ${GPU_COUNT} -gt 0 ]; then
    if [ "${GPU_TYPE}" == "h100" ]; then
        GPU_TYPE="nvidia_h100_80gb_hbm3"
    elif [ "${GPU_TYPE}" == "h200" ]; then
        GPU_TYPE="nvidia_h200"
    elif [ "${GPU_TYPE}" == "a100" ]; then
        GPU_TYPE="nvidia_a100-sxm4-80gb"
    elif [ "${GPU_TYPE}" == "a100-80gb" ]; then
        GPU_TYPE="nvidia_a100-sxm4-80gb"
    elif [ "${GPU_TYPE}" == "a100-40gb" ]; then
        GPU_TYPE="nvidia_a100-sxm4-40gb"
    elif [ "${GPU_TYPE}" == "a40" ]; then
        GPU_TYPE="nvidia_a40"
    elif [ "${GPU_TYPE}" == "a100mig" ]; then
        GPU_TYPE="nvidia_a100_3g.20gb"
    else
        print_log "Invalid GPU type: ${GPU_TYPE}"
        exit 1
    fi
    GRES_ARGS=(--gres=gpu:${GPU_TYPE}:${GPU_COUNT})
fi

s=$(sbatch -p ${PARTITION} \
      -J ${JOB_NAME} \
      --mem=${MEM_GB}g \
      --time=${TIMEOUT_STRING} \
      -c ${CPU_CORE} \
      --mail-type=ALL \
      --output=logs/%x.%j.out \
      --error=logs/%x.%j.err \
      "${GRES_ARGS[@]}" \
      /n/holylabs/juncheng_lab/Lab/software/scripts/sleep.sh)
job_id=$(echo $s | awk '{print $4}')
print_log "job_id: $job_id, waiting for job to start"

while true; do
    # Run the squeue command and capture output
    s=$(squeue|grep $(whoami) | grep $job_id)

    if [ -n "$s" ]; then
        # Check if 8th column starts with "holy"
        eighth_column=$(echo "$s" | awk '{print $8}')
        if [[ "$eighth_column" == holy* ]]; then
            echo ""
            # echo "SUCCESS: 8th column starts with 'holy'!"
            # echo "Final status: $s"
            print_log "successfully allocated server job_id $job_id server ${eighth_column}"
            mkdir -p ~/.alloc 2>/dev/null
            echo "${eighth_column}" > ~/.alloc/${JOB_NAME}
            break
        fi
        
        # echo "8th column: '$eighth_column' (not starting with 'holy' yet)"
    else
        print_log "No matching jobs found ($(whoami) + h100)"
    fi

    echo -ne "."    
    sleep 5
done
