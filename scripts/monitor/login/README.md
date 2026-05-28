# Login Node Monitor

Collects snapshots of system metrics on all login nodes every 5 minutes and writes them as JSONL.

## Files

| File | Purpose |
|------|---------|
| `login_monitor.sh` | Daemon that runs on a single node and collects metrics |
| `deploy_monitor.sh` | SSH wrapper that starts/stops/checks the daemon across all login nodes |
| `snapshot.py` | Python script invoked per snapshot — collects all metrics in parallel and prints one JSON line |

## Quick Start

```bash
# Start on all login nodes
./deploy_monitor.sh start

# Check that all daemons are running
./deploy_monitor.sh status

# Pretty-print the latest snapshot from each node
./deploy_monitor.sh tail

# Stop all daemons
./deploy_monitor.sh stop
```

## Monitored Nodes

By default, both sets of login nodes are targeted:

- `holylogin05` – `holylogin08`
- `boslogin05` – `boslogin08`

Override at runtime:

```bash
LOGIN_MONITOR_NODES="holylogin05 holylogin06" ./deploy_monitor.sh start
```

## Output Format

Each snapshot is one JSON line appended to `scripts/monitor/logs/YYYY-MM-DD/<hostname>.jsonl`.  
Logs land on the shared filesystem and are readable from any login node.

```
scripts/monitor/logs/
  2026-05-27/
    holylogin05.jsonl
    holylogin06.jsonl
    ...
    boslogin06.jsonl
    ...
```

Each JSON object contains:

| Field | Source | Description |
|-------|--------|-------------|
| `timestamp` | — | Snapshot time |
| `hostname` | — | Node name |
| `uptime` | `uptime` | Users logged in, 1/5/15-min load averages |
| `logged_in_users` | `w` | Per-session user, TTY, idle time, current command |
| `process_states` | `ps` | Count of running / blocked-on-IO / sleeping / zombie / stopped |
| `memory` | `free -b` | Total, used, free, available (GB) for RAM and swap |
| `cpu` | `mpstat -P ALL` | Per-core usr/sys/iowait/idle (1-sec average) |
| `vmstat` | `vmstat` | Context switches, interrupts, block IO rates |
| `local_disk_io` | `iostat -xz` | Per-device r/w kB/s, await, %util (1-sec real interval) |
| `nfs_io` | `nfsiostat` | Active NFS mounts — ops/s, read/write kB/s and RTT (5-sec real interval) |
| `network_io` | `sar -n DEV` | Per-interface rx/tx kB/s and packet rate (1-sec real interval) |
| `socket_summary` | `ss -s` | TCP established/timewait/orphaned, UDP totals |
| `per_user_resources` | `ps` | Aggregate CPU%, RSS, and process count per user |
| `top_cpu_processes` | `ps` | Top 25 processes by CPU%, with full args |
| `top_rss_processes` | `ps` | Top 25 processes by RSS, with full args |
| `top_io_processes` | `pidstat -dl` | Top 25 processes by IO delay |
| `system_fds` | `/proc/sys/fs/file-nr` | System-wide file descriptor allocated/free/max |

## Querying Logs

```bash
# Pretty-print the latest snapshot for one node
tail -1 logs/2026-05-27/holylogin07.jsonl | jq .

# Show load average and user count across all snapshots for a node
jq '{timestamp, load: .uptime.load_1, users: .uptime.users}' \
    logs/2026-05-27/holylogin07.jsonl

# Find snapshots where load exceeded 2000
jq 'select(.uptime.load_1 > 2000) | {timestamp, load: .uptime.load_1}' \
    logs/2026-05-27/holylogin07.jsonl

# Top user by CPU in the latest snapshot
tail -1 logs/2026-05-27/holylogin07.jsonl \
    | jq '.per_user_resources[0]'

# NFS mounts with high read latency (>50ms RTT)
tail -1 logs/2026-05-27/holylogin07.jsonl \
    | jq '.nfs_io[] | select(.rd_rtt_ms > 50)'
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOGIN_MONITOR_OUTPUT_DIR` | `scripts/monitor/logs` | Directory for JSONL files |
| `LOGIN_MONITOR_PID_DIR` | `~/.run` | Directory for PID files |
| `LOGIN_MONITOR_NODES` | all 8 nodes | Space-separated list of nodes for `deploy_monitor.sh` |

```bash
# Write to shared lab storage instead
LOGIN_MONITOR_OUTPUT_DIR=/n/holylabs/.../monitor ./deploy_monitor.sh start
```

## Single-Node Usage

```bash
./login_monitor.sh start    # start background daemon
./login_monitor.sh status   # check if running
./login_monitor.sh once     # take one snapshot immediately and exit
./login_monitor.sh stop     # stop the daemon
```

## Log Rotation

A new file is created each day automatically. To prune old files:

```bash
find scripts/monitor/logs -name "*.jsonl" -mtime +30 -delete
```
