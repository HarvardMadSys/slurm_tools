#!/usr/bin/env bash
# Collects per-snapshot metrics (CPU, IO, top processes) on a login node.
# Usage:
#   login_monitor.sh start   -- start background daemon
#   login_monitor.sh stop    -- stop running daemon
#   login_monitor.sh status  -- show daemon status
#   login_monitor.sh once    -- take a single snapshot and exit
#
# Output goes to: $OUTPUT_DIR/<YYYY-MM-DD>/<hostname>.jsonl  (one file per day per node)
# PID file:       $PID_DIR/login_monitor_<hostname>.pid

set -euo pipefail

INTERVAL=300  # seconds between snapshots
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${LOGIN_MONITOR_OUTPUT_DIR:-${SCRIPT_DIR}/logs}"
PID_DIR="${LOGIN_MONITOR_PID_DIR:-${HOME}/.run}"
HOSTNAME="$(hostname -s)"
TOP_N=25       # processes to capture per snapshot

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_log_file() {
    local day
    day="$(date +%Y-%m-%d)"
    local dir="${OUTPUT_DIR}/${day}"
    mkdir -p "$dir"
    printf '%s/%s.jsonl' "$dir" "$HOSTNAME"
}

_pid_file() {
    printf '%s/login_monitor_%s.pid' "$PID_DIR" "$HOSTNAME"
}

_snapshot() {
    python3 "${SCRIPT_DIR}/snapshot.py" "$HOSTNAME" "$TOP_N" >> "$(_log_file)"
}

# ---------------------------------------------------------------------------
# daemon loop
# ---------------------------------------------------------------------------

_daemon() {
    local pid_file
    pid_file="$(_pid_file)"
    mkdir -p "$PID_DIR"
    printf '%d\n' "$$" > "$pid_file"
    trap 'rm -f "$pid_file"' EXIT

    while true; do
        _snapshot || true
        sleep "$INTERVAL"
    done
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_start() {
    local pid_file
    pid_file="$(_pid_file)"
    if [[ -f "$pid_file" ]]; then
        local old_pid
        old_pid="$(cat "$pid_file")"
        if kill -0 "$old_pid" 2>/dev/null; then
            printf 'login_monitor already running on %s (pid %s)\n' "$HOSTNAME" "$old_pid"
            return 0
        fi
        rm -f "$pid_file"
    fi
    mkdir -p "$OUTPUT_DIR" "$PID_DIR"
    nohup bash "$0" _daemon_internal \
        > "${OUTPUT_DIR}/login_monitor_${HOSTNAME}_nohup.log" 2>&1 &
    local new_pid=$!
    printf 'login_monitor started on %s (pid %d)\n' "$HOSTNAME" "$new_pid"
}

cmd_stop() {
    local pid_file
    pid_file="$(_pid_file)"
    if [[ ! -f "$pid_file" ]]; then
        printf 'login_monitor not running on %s (no pid file)\n' "$HOSTNAME"
        return 0
    fi
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        printf 'login_monitor stopped on %s (pid %s)\n' "$HOSTNAME" "$pid"
    else
        printf 'login_monitor pid %s not found on %s (stale pid file removed)\n' "$pid" "$HOSTNAME"
    fi
    rm -f "$pid_file"
}

cmd_status() {
    local pid_file
    pid_file="$(_pid_file)"
    if [[ ! -f "$pid_file" ]]; then
        printf 'login_monitor: NOT RUNNING on %s\n' "$HOSTNAME"
        return 0
    fi
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
        printf 'login_monitor: RUNNING on %s (pid %s)\n' "$HOSTNAME" "$pid"
    else
        printf 'login_monitor: STALE pid file on %s (pid %s not alive)\n' "$HOSTNAME" "$pid"
    fi
}

case "${1:-}" in
    start)           cmd_start ;;
    stop)            cmd_stop ;;
    status)          cmd_status ;;
    once)            _snapshot ;;
    _daemon_internal) _daemon ;;
    *)
        printf 'Usage: %s {start|stop|status|once}\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac
