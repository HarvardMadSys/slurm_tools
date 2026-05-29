#!/usr/bin/env bash
# Collect per-node process, compute, and IO snapshots on a compute node.
# Usage:
#   compute_monitor.sh once             -- take a single snapshot and exit
#   compute_monitor.sh status_once      -- report monitor status for this node
#   compute_monitor.sh stop_local       -- stop monitor loop for this node
#   compute_monitor.sh cleanup_pid      -- remove this node's pid file
#
# Internal:
#   compute_monitor.sh _daemon_internal -- run the monitor loop in the foreground

set -euo pipefail

INTERVAL="${COMPUTE_MONITOR_INTERVAL:-60}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${COMPUTE_MONITOR_OUTPUT_DIR:-${SCRIPT_DIR}/logs}"
PID_DIR="${COMPUTE_MONITOR_PID_DIR:-${HOME}/.run}"
HOSTNAME="$(hostname -s)"
JOB_ID="${COMPUTE_MONITOR_JOB_ID:-${SLURM_JOB_ID:-nojob}}"

_has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

_job_root() {
    printf '%s/job_%s' "$OUTPUT_DIR" "$JOB_ID"
}

_log_file() {
    local day dir prefix
    day="$(date +%Y-%m-%d)"
    dir="$(_job_root)/${day}"
    mkdir -p "$dir"
    prefix="${SLURM_JOB_PARTITION:+${SLURM_JOB_PARTITION}_}"
    printf '%s/%s%s.log' "$dir" "$prefix" "$HOSTNAME"
}

_pid_file() {
    mkdir -p "$PID_DIR"
    printf '%s/compute_monitor_%s_%s.pid' "$PID_DIR" "$JOB_ID" "$HOSTNAME"
}

_pid_field() {
    local key="$1" pid_file="$2"
    awk -F= -v wanted="$key" '$1 == wanted { print $2; exit }' "$pid_file" 2>/dev/null || true
}

_pid_matches_monitor() {
    local pid="$1" args
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ "$args" == *"compute_monitor.sh _daemon_internal"* ]]
}

_write_pid_file() {
    local pid_file
    pid_file="$(_pid_file)"
    cat > "$pid_file" <<EOF
pid=$$
host=$HOSTNAME
job_id=$JOB_ID
step_id=${SLURM_STEP_ID:-}
started_at=$(date -Is)
EOF
}

_snapshot() {
    local ts log apps
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    log="$(_log_file)"

    {
        printf '\n'
        printf '=== %s [%s] job=%s step=%s ===\n' "$ts" "$HOSTNAME" "$JOB_ID" "${SLURM_STEP_ID:-na}"

        printf '\n--- Uptime / Load Average ---\n'
        uptime || true

        printf '\n--- Memory ---\n'
        free -h || true

        printf '\n--- CPU Utilization (mpstat -P ALL, 1-sec avg) ---\n'
        if _has_cmd mpstat; then
            mpstat -P ALL 1 1 2>/dev/null | grep -E '^(Average:|Linux)' || true
        else
            printf 'mpstat not found\n'
        fi

        printf '\n--- Disk IO (iostat -xz, 1-sec avg) ---\n'
        if _has_cmd iostat; then
            iostat -xz 1 2 2>/dev/null | awk '/^avg-cpu/{n++} n>=2{print}' || true
        else
            printf 'iostat not found\n'
        fi

        printf '\n--- NFS IO (active mounts only) ---\n'
        if _has_cmd nfsiostat; then
            printf '%-40s %8s  %10s %8s %8s  %10s %8s %8s\n' \
                "mountpoint" "ops/s" "rd_kB/s" "rd_rtt" "rd_que" "wr_kB/s" "wr_rtt" "wr_que"
            printf '%-40s %8s  %10s %8s %8s  %10s %8s %8s\n' \
                "" "" "" "(ms)" "(ms)" "" "(ms)" "(ms)"
            nfsiostat 1 2 2>/dev/null | awk '
                /mounted on/ {
                    match($0, /mounted on ([^:]+)/, a); mp=a[1]
                    ops=0; rkb=0; rrtt=0; rexe=0; wkb=0; wrtt=0; wexe=0; state=0; next
                }
                /^[[:space:]]+ops\/s/            { state=1; next }
                state==1 && /^[[:space:]]+[0-9]/ { ops=$1; state=0; next }
                /^read:/                          { state=2; next }
                state==2 && /^[[:space:]]+[0-9]/ {
                    rkb=$2; rrtt=$(NF-1); rexe=$NF; state=0; next
                }
                /^write:/                         { state=3; next }
                state==3 && /^[[:space:]]+[0-9]/ {
                    wkb=$2; wrtt=$(NF-1); wexe=$NF; state=0
                    if (ops > 0.005)
                        printf "%-40s %8.3f  %10.1f %8.1f %8.1f  %10.1f %8.1f %8.1f\n",
                            mp, ops, rkb, rrtt, rexe-rrtt, wkb, wrtt, wexe-wrtt
                }
            ' | sort -k2 -rn || true
        else
            printf 'nfsiostat not found\n'
        fi

        printf '\n--- NFS RPC Stats (retransmits since mount) ---\n'
        if [[ -r /proc/net/rpc/nfs ]]; then
            awk '/^rpc /{printf "calls=%s  retransmissions=%s  auth_refreshes=%s\n",$2,$3,$4}' \
                /proc/net/rpc/nfs
        else
            printf '/proc/net/rpc/nfs not readable\n'
        fi

        printf '\n--- NFS Mountstats (cumulative RTT breakdown + retransmits) ---\n'
        # avg_queue = client slot-table wait; avg_rtt = server+network; bad_xid > 0 = serious
        if [[ -r /proc/self/mountstats ]]; then
            awk '
            /mounted on .* with fstype nfs/ {
                match($0, /mounted on ([^ :]+)/, a); mp=a[1]
                printf "\n%s\n", mp; next
            }
            mp && /xprt:.*tcp/ {
                # fields: xprt: tcp srcport bind conn_cnt conn_time idle sends recvs bad_xid req_u backlog_u
                printf "  xprt:  bad_xid=%s  avg_slot=%.2f  avg_backlog=%.2f\n", $10, $11, $12; next
            }
            mp && /^[[:space:]]+(READ|WRITE):/ {
                op=$1; ops=$2; retrans=$3; q_ms=$6; rtt_ms=$7; exe_ms=$8
                if (ops > 0)
                    printf "  %-7s ops=%d retrans=%d avg_queue=%.2fms avg_rtt=%.2fms avg_exe=%.2fms\n",
                        op, ops, retrans, q_ms/ops, rtt_ms/ops, exe_ms/ops
            }
            ' /proc/self/mountstats
        else
            printf '/proc/self/mountstats not readable\n'
        fi

        printf '\n--- D-State Processes (blocked in uninterruptible I/O wait) ---\n'
        ps axo stat,pid,user,args --no-headers 2>/dev/null \
            | awk '$1 ~ /^D/ {print}' || true

        printf '\n--- Sleeping Process Wait Channels ---\n'
        printf '%-6s  %-20s  %s\n' COUNT WCHAN COMMAND
        ps axo pid,stat,wchan=WAIT,comm --no-headers 2>/dev/null \
            | awk '$2 ~ /^S/ {print $3, $4}' \
            | sort | uniq -c | sort -rn | head -20 \
            | awk '{printf "%-6s  %-20s  %s\n", $1, $2, $3}' || true

        printf '\n--- Top Sleeping Processes (wchan + syscall) ---\n'
        ps axo pid,ppid,user,%cpu,stat,wchan=WAIT,args --no-headers --sort=-%cpu 2>/dev/null \
            | awk '$5 ~ /^S/ {print $1, $2, $3, $4, $6}' | head -20 \
            | while read -r pid ppid user cpu wchan; do
                syscall="$(cat "/proc/$pid/syscall" 2>/dev/null || echo 'N/A')"
                printf 'pid=%-8s user=%-12s cpu=%-5s wchan=%-20s syscall=%s\n' \
                    "$pid" "$user" "$cpu" "$wchan" "$syscall"
            done || true

        printf '\n--- GPU Summary (nvidia-smi) ---\n'
        if _has_cmd nvidia-smi; then
            nvidia-smi \
                --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,pstate,clocks.current.sm,clocks.current.memory \
                --format=csv,noheader,nounits 2>/dev/null || true
        else
            printf 'nvidia-smi not found\n'
        fi

        printf '\n--- GPU Process Utilization (nvidia-smi pmon) ---\n'
        if _has_cmd nvidia-smi; then
            nvidia-smi pmon -c 1 2>/dev/null || true
        else
            printf 'nvidia-smi not found\n'
        fi

        printf '\n--- GPU Compute Apps (nvidia-smi query-compute-apps) ---\n'
        if _has_cmd nvidia-smi; then
            apps="$(nvidia-smi \
                --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory \
                --format=csv,noheader,nounits 2>/dev/null || true)"
            if [[ -n "${apps//[[:space:]]/}" ]]; then
                printf '%s\n' "$apps"
            else
                printf 'no active GPU compute apps\n'
            fi
        else
            printf 'nvidia-smi not found\n'
        fi

        printf '\n--- All Processes (ps sorted by CPU%%) ---\n'
        ps -eo pid,ppid,user,%cpu,%mem,rss,stat,wchan,start,time,args --sort=-%cpu || true

        printf '\n--- Per-Process IO (pidstat -dhl, 1-sec avg) ---\n'
        if _has_cmd pidstat; then
            pidstat -dhl 1 1 2>/dev/null || true
        else
            printf 'pidstat not found\n'
        fi

        printf '\n--- System File Descriptors ---\n'
        if [[ -r /proc/sys/fs/file-nr ]]; then
            awk '{printf "allocated=%s  free=%s  max=%s\n", $1, $2, $3}' /proc/sys/fs/file-nr
        else
            printf '/proc/sys/fs/file-nr not readable\n'
        fi

        printf '\n'
    } >> "$log"
}

_daemon() {
    local pid_file
    pid_file="$(_pid_file)"
    _write_pid_file
    trap 'rm -f "$pid_file"' EXIT

    while true; do
        _snapshot || true
        sleep "$INTERVAL"
    done
}

cmd_status_once() {
    local pid_file pid step_id
    pid_file="$(_pid_file)"
    if [[ ! -f "$pid_file" ]]; then
        printf 'compute_monitor: NOT RUNNING on %s (job %s)\n' "$HOSTNAME" "$JOB_ID"
        return 0
    fi

    pid="$(_pid_field pid "$pid_file")"
    step_id="$(_pid_field step_id "$pid_file")"
    if [[ -z "$pid" ]]; then
        printf 'compute_monitor: STALE pid file on %s (job %s)\n' "$HOSTNAME" "$JOB_ID"
        return 0
    fi

    if kill -0 "$pid" 2>/dev/null && _pid_matches_monitor "$pid"; then
        printf 'compute_monitor: RUNNING on %s (job %s, pid %s, step %s)\n' \
            "$HOSTNAME" "$JOB_ID" "$pid" "${step_id:-unknown}"
    else
        printf 'compute_monitor: STALE pid file on %s (job %s, pid %s)\n' \
            "$HOSTNAME" "$JOB_ID" "$pid"
    fi
}

cmd_stop_local() {
    local pid_file pid
    pid_file="$(_pid_file)"
    if [[ ! -f "$pid_file" ]]; then
        printf 'compute_monitor: NOT RUNNING on %s (job %s)\n' "$HOSTNAME" "$JOB_ID"
        return 0
    fi

    pid="$(_pid_field pid "$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && _pid_matches_monitor "$pid"; then
        kill "$pid" 2>/dev/null || true
        printf 'compute_monitor: STOPPED on %s (job %s, pid %s)\n' "$HOSTNAME" "$JOB_ID" "$pid"
    else
        printf 'compute_monitor: STALE pid file on %s (job %s)\n' "$HOSTNAME" "$JOB_ID"
    fi
    rm -f "$pid_file"
}

cmd_cleanup_pid() {
    rm -f "$(_pid_file)"
}

case "${1:-}" in
    once)             _snapshot ;;
    status_once)      cmd_status_once ;;
    stop_local)       cmd_stop_local ;;
    cleanup_pid)      cmd_cleanup_pid ;;
    _daemon_internal) _daemon ;;
    *)
        printf 'Usage: %s {once|status_once|stop_local|cleanup_pid}\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac
