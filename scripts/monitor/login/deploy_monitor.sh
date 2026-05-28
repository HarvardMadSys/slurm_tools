#!/usr/bin/env bash
# Deploy and control login_monitor.sh across all login nodes.
# Usage:
#   deploy_monitor.sh start   -- start daemon on all login nodes
#   deploy_monitor.sh stop    -- stop daemon on all login nodes
#   deploy_monitor.sh status  -- check daemon status on all login nodes
#   deploy_monitor.sh tail    -- tail today's log for each node
#
# Override node list:  LOGIN_MONITOR_NODES="holylogin05 holylogin06" deploy_monitor.sh start
# Override output dir: LOGIN_MONITOR_OUTPUT_DIR=/scratch/monitor deploy_monitor.sh start

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/login_monitor.sh"

# Default login nodes; override with LOGIN_MONITOR_NODES env var.
DEFAULT_NODES="holylogin05 holylogin06 holylogin07 holylogin08 boslogin05 boslogin06 boslogin07 boslogin08"
LOGIN_NODES="${LOGIN_MONITOR_NODES:-$DEFAULT_NODES}"

OUTPUT_DIR="${LOGIN_MONITOR_OUTPUT_DIR:-${SCRIPT_DIR}/logs}"

# Extra env vars to forward to the remote script.
FORWARD_VARS=(
    "LOGIN_MONITOR_OUTPUT_DIR=${OUTPUT_DIR}"
    "LOGIN_MONITOR_PID_DIR=${HOME}/.run"
)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_run_on_node() {
    local node="$1" cmd="$2"
    local env_str
    env_str="$(printf '%s ' "${FORWARD_VARS[@]}")"
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
        "$node" \
        "env ${env_str} bash '${MONITOR_SCRIPT}' ${cmd}"
}

_run_all() {
    local cmd="$1"
    local node
    for node in $LOGIN_NODES; do
        printf '[%s] ' "$node"
        _run_on_node "$node" "$cmd" 2>&1 || printf 'ERROR reaching %s\n' "$node"
    done
}

# ---------------------------------------------------------------------------
# commands
# ---------------------------------------------------------------------------

cmd_start() {
    printf 'Starting login_monitor on: %s\n' "$LOGIN_NODES"
    _run_all "start"
}

cmd_stop() {
    printf 'Stopping login_monitor on: %s\n' "$LOGIN_NODES"
    _run_all "stop"
}

cmd_status() {
    printf 'Checking login_monitor status on: %s\n' "$LOGIN_NODES"
    _run_all "status"
}

cmd_tail() {
    local day n
    day="$(date +%Y-%m-%d)"
    n="${1:-1}"   # number of snapshots to show per node (default 1)
    printf 'Last %d snapshot(s) per node for %s:\n' "$n" "$day"
    local node
    for node in $LOGIN_NODES; do
        local f="${OUTPUT_DIR}/${day}/${node}.jsonl"
        if [[ -f "$f" ]]; then
            printf '\n=== %s ===\n' "$node"
            tail -n "$n" "$f" | jq .
        else
            printf '[%s] no log: %s\n' "$node" "$f"
        fi
    done
}

case "${1:-}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    tail)    cmd_tail "${2:-}" ;;
    *)
        printf 'Usage: %s {start|stop|status|tail}\n' "$(basename "$0")" >&2
        exit 1
        ;;
esac
