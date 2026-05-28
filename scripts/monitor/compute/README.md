# Compute Node Monitor

Launches a lightweight monitoring loop on compute nodes and writes snapshots to shared storage. It can either attach to an existing allocation or submit dedicated monitoring allocations across one partition, a list of partitions, or all visible partitions.

## Files

| File | Purpose |
|------|---------|
| `compute_monitor.sh` | Per-node worker that captures process, compute, and IO snapshots |
| `launch_monitor.sh` | Slurm-aware launcher/controller for existing or self-submitted monitor jobs |

## Quick Start

### Existing Allocation

Run from inside the allocation or set `COMPUTE_MONITOR_JOB_ID` from a login node:

```bash
# Start one monitor task per compute node
./launch_monitor.sh start

# Check status on every node
./launch_monitor.sh status

# Tail today's logs
./launch_monitor.sh tail

# Stop the monitor
./launch_monitor.sh stop
```

### Allocate All Nodes In One Partition

To have the monitor allocate its own nodes, set a partition and submit a dedicated monitoring job:

```bash
COMPUTE_MONITOR_PARTITION=gpu_h200 ./launch_monitor.sh allocate

# Later, inspect or stop it
./launch_monitor.sh status
./launch_monitor.sh stop
```

By default, `allocate` targets every node in the partition whose state is currently allocatable (`idle`, `mixed`, `allocated`, or `completing`) and asks Slurm for them as one exclusive job. That means the job may stay pending until the whole node set becomes available.

When you do not set `COMPUTE_MONITOR_TIME`, the launcher now uses a cluster-safe default of `00:30:00`, and automatically stretches `intermediate` plus `bigmem_intermediate` to `3-00:01:00` because those partitions reject shorter jobs.

### Allocate Across Multiple Partitions

A single Slurm job does not actually run across every partition at once, so the launcher handles this by submitting one monitor job per target partition and tracking them together:

```bash
# One job for each listed partition
COMPUTE_MONITOR_PARTITION=gpu_h200,gpu_test ./launch_monitor.sh allocate

# One job for every visible partition
COMPUTE_MONITOR_PARTITION=all ./launch_monitor.sh allocate

# Aggregate status / stop across all tracked monitor jobs
./launch_monitor.sh status
./launch_monitor.sh stop
```

When `COMPUTE_MONITOR_PARTITION=all`, the script discovers visible partitions with `sinfo`, filters out duplicates, and then submits one allocation per partition. If one partition cannot be allocated, the others can still be submitted.

## Output

Logs are written to:

```text
scripts/monitor/compute/logs/job_<jobid>/YYYY-MM-DD/<hostname>.log
```

Each snapshot includes:

- Uptime and load average
- Memory usage
- Per-core CPU utilization from `mpstat`
- Local disk IO from `iostat`
- NFS IO from `nfsiostat`
- GPU utilization and GPU process snapshots from `nvidia-smi`
- Full process table from `ps`
- Per-process IO from `pidstat`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPUTE_MONITOR_JOB_ID` | `SLURM_JOB_ID` or the remembered monitor job | Slurm job to monitor |
| `COMPUTE_MONITOR_NODES` | all nodes in the job | Optional space-separated subset of nodes |
| `COMPUTE_MONITOR_OUTPUT_DIR` | `scripts/monitor/compute/logs` | Root directory for logs |
| `COMPUTE_MONITOR_PID_DIR` | `~/.run` | Directory for per-node pid files |
| `COMPUTE_MONITOR_INTERVAL` | `60` | Seconds between snapshots |
| `COMPUTE_MONITOR_PARTITION` | unset | Partition name, comma-separated partition list, or `all` for `allocate` |
| `COMPUTE_MONITOR_ACCOUNT` | unset | Optional Slurm account for `allocate` |
| `COMPUTE_MONITOR_QOS` | unset | Optional Slurm QOS for `allocate` |
| `COMPUTE_MONITOR_TIME` | `00:30:00` | Optional time limit for `allocate`; `intermediate` and `bigmem_intermediate` are automatically raised when unset |
| `COMPUTE_MONITOR_CONSTRAINT` | unset | Optional Slurm constraint for `allocate` |
| `COMPUTE_MONITOR_RESERVATION` | unset | Optional Slurm reservation for `allocate` |
| `COMPUTE_MONITOR_EXCLUDE` | unset | Optional node exclude list for `allocate` |
| `COMPUTE_MONITOR_EXCLUDE_PARTITIONS` | unset | Optional comma-separated partition names to skip when using a list or `all` |
| `COMPUTE_MONITOR_ALLOCATE_NODELIST` | unset | Optional explicit Slurm nodelist expression instead of “all eligible nodes” |
| `COMPUTE_MONITOR_STATE_FILE` | `~/.run/compute_monitor_jobs.tsv` | Tracks the monitor allocations submitted by `allocate` |
| `COMPUTE_MONITOR_GPUS_PER_NODE` | `1` | GPU request automatically added on GPU partitions |
| `COMPUTE_MONITOR_BIGMEM_MIN_MEMORY` | `1001G` | Memory request automatically added on `bigmem*` partitions |

Example:

```bash
COMPUTE_MONITOR_JOB_ID=123456 \
COMPUTE_MONITOR_INTERVAL=30 \
./launch_monitor.sh start

COMPUTE_MONITOR_PARTITION=gpu_h200 \
COMPUTE_MONITOR_TIME=04:00:00 \
./launch_monitor.sh allocate

COMPUTE_MONITOR_PARTITION=all \
COMPUTE_MONITOR_EXCLUDE_PARTITIONS=remoteviz,test \
COMPUTE_MONITOR_TIME=02:00:00 \
./launch_monitor.sh allocate
```

## One-Off Snapshots

To capture a single snapshot on every node without starting the background loop:

```bash
./launch_monitor.sh once
```
