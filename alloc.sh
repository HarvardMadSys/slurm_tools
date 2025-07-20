#!/bin/bash

# usage: bash $0 -j JOB_NAME -c CPU_CORE -m MEM_GB -u GPU_TYPE -g GPU_COUNT -t TIMEOUT_HOURS

# default values
JOB_NAME="h100_$(whoami)"
CPU_CORE=16
MEM_GB=256
GPU_TYPE="h100"
GPU_COUNT=0
TIMEOUT_HOURS=12
PARTITION="best"

usage(){
    echo "usage: $0 [-j JOB_NAME] [-c CPU_CORE] [-m MEM_GB] [-u GPU_TYPE] [-g GPU_COUNT] [-t TIMEOUT_HOURS] [-p PARTITION]"
    echo "default values: JOB_NAME=h100_$(whoami), CPU_CORE=16, MEM_GB=256, GPU_TYPE=h100, GPU_COUNT=1, TIMEOUT_HOURS=12, PARTITION=best"
    echo "example: $0 -j h100_$(whoami) -c 16 -m 256 -g 1 -u h100 -t 12 -p best"
    echo "gpu types: h100, a100, a100-80gb, a100-40gb, a40, h200"
    echo ""
    echo "Options:"
    echo "  -j JOB_NAME        Job name (default: h100_$(whoami))"
    echo "  -c CPU_CORE        Number of CPU cores (default: 16)"
    echo "  -m MEM_GB          Memory in GB (default: 256)"
    echo "  -u GPU_TYPE        GPU type (default: h100)"
    echo "  -g GPU_COUNT       Number of GPUs (default: 1)"
    echo "  -t TIMEOUT_HOURS   Timeout in hours (default: 12)"
    echo "  -p PARTITION       Partition (default: best)"
    echo "  -h                 Show this help message"
    exit 1
}

print_log() {
    echo $(date +%Y-%m-%d\ %H:%M:%S) $1
}

# cancel the job if user ctrl+c
trap 'echo "Ctrl+C pressed, cancelling job..."; scancel $job_id; exit 1' INT

# Parse command line arguments
while getopts "j:c:m:g:n:t:p:h" opt; do
    case $opt in
        j) JOB_NAME="$OPTARG" ;;
        c) CPU_CORE="$OPTARG" ;;
        m) MEM_GB="$OPTARG" ;;
        u) GPU_TYPE="$OPTARG" ;;
        g) GPU_COUNT="$OPTARG" ;;
        t) TIMEOUT_HOURS="$OPTARG" ;;
        p) PARTITION="$OPTARG" ;;
        h) usage ;;
        \?) echo "Invalid option -$OPTARG" >&2; usage ;;
    esac
done

# if PARTITION is best, find the best partition
if [ "${PARTITION}" == "best" ]; then
    PARTITION=$(best_partition -n -c ${CPU_CORE} -m ${MEM_GB} --gpu-type ${GPU_TYPE} -g ${GPU_COUNT} -t ${TIMEOUT_HOURS} --name-only)
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

if [ "${GPU_TYPE}" == "h100" ]; then
    GPU_TYPE="nvidia_h100_80gb_hbm3"
elif [ "${GPU_TYPE}" == "a100" ]; then
    GPU_TYPE="nvidia_a100-sxm4-80gb"
elif [ "${GPU_TYPE}" == "a100-80gb" ]; then
    GPU_TYPE="nvidia_a100-sxm4-80gb"
elif [ "${GPU_TYPE}" == "a100-40gb" ]; then
    GPU_TYPE="nvidia_a100-sxm4-40gb"
elif [ "${GPU_TYPE}" == "a40" ]; then
    GPU_TYPE="nvidia_a40"
elif [ "${GPU_TYPE}" == "h200" ]; then
    GPU_TYPE="nvidia_h200"
else
    print_log "Invalid GPU type: ${GPU_TYPE}"
    exit 1
fi

s=$(sbatch -p ${PARTITION} \
      -J ${JOB_NAME} \
      --mem=${MEM_GB}g \
      --time=${TIMEOUT_STRING} \
      -c ${CPU_CORE} \
      --output=logs/%x.%j.out \
      --error=logs/%x.%j.err \
      --gres=gpu:${GPU_TYPE}:${GPU_COUNT} \
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
            break
        fi
        
        # echo "8th column: '$eighth_column' (not starting with 'holy' yet)"
    else
        print_log "No matching jobs found ($(whoami) + h100)"
    fi

    echo -ne "."    
    sleep 5
done
