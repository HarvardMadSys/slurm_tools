# Compute Node Monitor

Captures system snapshots on compute nodes and writes them to shared storage. Two operating modes:

- **`cycle`** — submit short one-shot jobs every few minutes across all available nodes, collecting one snapshot per visit (minimal resource footprint, rotates across the cluster automatically)
- **`allocate`** / **`start`** — submit long-running exclusive jobs that collect snapshots continuously at a fixed interval

## Files

| File | Purpose |
|------|---------|
| `compute_monitor.sh` | Per-node worker: captures CPU, memory, IO, GPU, and process snapshots |
| `launch_monitor.sh` | Slurm-aware launcher/controller for all operating modes |

---

## Cycle Mode (recommended for broad coverage)

Submits one-shot snapshot jobs to all available nodes in the target partitions, waits, then repeats. Each job requests one CPU per node (no `--exclusive`), runs a single snapshot (~10 s), then self-cancels. On each iteration, different nodes may be free, so coverage rotates **naturally** across the cluster.

Default target partitions: `test`, `test_gpu`, `serial_requeue`, `gpu_requeue`.

```bash
# Run in a screen/tmux session — blocks and loops forever
./launch_monitor.sh cycle
```

Override partitions or timing:

```bash
COMPUTE_MONITOR_PARTITION=gpu_requeue,serial_requeue \
COMPUTE_MONITOR_CYCLE_INTERVAL=600 \
./launch_monitor.sh cycle
```

What happens each iteration:

1. Prune finished jobs from the state file
2. For each target partition, find nodes in `idle`/`mixed`/`allocated`/`completing` state
3. Submit `sbatch --cpus-per-task=1 --ntasks-per-node=1` to those nodes; the batch script runs `srun ... compute_monitor.sh once` then calls `scancel` to release the allocation immediately
4. Sleep `CYCLE_INTERVAL` seconds (default 5 minutes), then repeat

---

## Allocate Mode (continuous monitoring on a fixed node set)

Submits one long-running exclusive job per partition. Each job loops indefinitely, writing a snapshot every `COMPUTE_MONITOR_INTERVAL` seconds (default 60 s).

```bash
# Submit monitor jobs for the default four partitions
./launch_monitor.sh allocate

# Explicit partition list
COMPUTE_MONITOR_PARTITION=gpu_h200,gpu_test ./launch_monitor.sh allocate

# Every visible partition
COMPUTE_MONITOR_PARTITION=all ./launch_monitor.sh allocate

# Exclude some partitions when using "all"
COMPUTE_MONITOR_PARTITION=all \
COMPUTE_MONITOR_EXCLUDE_PARTITIONS=remoteviz,bigmem \
./launch_monitor.sh allocate
```

Inspect or stop the running allocations:

```bash
./launch_monitor.sh status
./launch_monitor.sh tail
./launch_monitor.sh stop
```

---

## Start Mode (attach to an existing allocation)

Run the monitor inside an allocation you already hold. Invoke from within the job, or set `COMPUTE_MONITOR_JOB_ID` from a login node.

```bash
./launch_monitor.sh start

./launch_monitor.sh status
./launch_monitor.sh tail
./launch_monitor.sh stop
```

Take a single snapshot without starting the background loop:

```bash
./launch_monitor.sh once
```

---

## Output

```
logs/
  job_<jobid>/
    YYYY-MM-DD/
      <partition>_<hostname>.log    # one file per node per day; partition prefix from $SLURM_JOB_PARTITION
  slurm/
    cycle_<jobid>.out   # stdout from cycle batch jobs
    cycle_<jobid>.err   # stderr from cycle batch jobs
    alloc_<jobid>.out   # stdout from allocate batch jobs
    alloc_<jobid>.err   # stderr from allocate batch jobs
```

Each snapshot section includes:

| Section | Tool | Notes |
|---------|------|-------|
| Uptime / load average | `uptime` | |
| Memory | `free -h` | |
| Per-core CPU | `mpstat -P ALL 1 1` | 1-second real interval |
| Local disk IO | `iostat -xz 1 2` | 1-second real interval, second sample only |
| NFS IO | `nfsiostat 1 2` | 1-second real interval — ops/s, kB/s, RTT, queue latency |
| NFS RPC retransmits | `/proc/net/rpc/nfs` | Cumulative since mount |
| NFS mountstats | `/proc/self/mountstats` | Cumulative RTT breakdown, bad_xid, slot backlog |
| D-state processes | `ps` | Processes blocked in uninterruptible IO wait |
| GPU summary | `nvidia-smi` | Utilization, memory, power, clocks per GPU |
| GPU process utilization | `nvidia-smi pmon` | Per-GPU per-process utilization |
| GPU compute apps | `nvidia-smi query-compute-apps` | Active CUDA processes and memory usage |
| All processes by CPU | `ps` | Full process table sorted by CPU% |
| Per-process IO | `pidstat -dhl 1 1` | 1-second real interval |
| System file descriptors | `/proc/sys/fs/file-nr` | |

---

## Environment Variables

### Job targeting

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPUTE_MONITOR_JOB_ID` | `$SLURM_JOB_ID` or auto-detected | Slurm job to attach to (`start`/`once`/`stop`/`status`/`tail`) |
| `COMPUTE_MONITOR_NODES` | all nodes in the job | Space-separated subset of nodes to monitor |
| `COMPUTE_MONITOR_PARTITION` | `test,test_gpu,serial_requeue,gpu_requeue` | Partition(s) for `allocate`/`cycle`; use `all` for every visible partition |
| `COMPUTE_MONITOR_EXCLUDE_PARTITIONS` | unset | Comma-separated partitions to skip when using a list or `all` |
| `COMPUTE_MONITOR_ALLOCATE_NODELIST` | unset | Explicit nodelist expression instead of all eligible nodes (single partition only) |

### Snapshot collection

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPUTE_MONITOR_INTERVAL` | `60` | Seconds between snapshots in daemon/allocate mode |
| `COMPUTE_MONITOR_OUTPUT_DIR` | `logs/` next to the script | Root directory for log files |
| `COMPUTE_MONITOR_PID_DIR` | `~/.run` | Directory for per-node PID files |

### Cycle mode

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPUTE_MONITOR_CYCLE_INTERVAL` | `300` | Seconds between cycle iterations (5 minutes) |
| `COMPUTE_MONITOR_CYCLE_JOB_TIME` | `00:05:00` | Slurm time limit for each one-shot cycle job |

### Allocate mode (sbatch options)

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPUTE_MONITOR_TIME` | `00:30:00` | Time limit for allocate jobs; `intermediate`/`bigmem_intermediate` auto-raised to `3-00:01:00` |
| `COMPUTE_MONITOR_ACCOUNT` | unset | Slurm account (`--account`) |
| `COMPUTE_MONITOR_QOS` | unset | Slurm QOS (`--qos`) |
| `COMPUTE_MONITOR_CONSTRAINT` | unset | Slurm constraint (`--constraint`) |
| `COMPUTE_MONITOR_RESERVATION` | unset | Slurm reservation (`--reservation`) |
| `COMPUTE_MONITOR_EXCLUDE` | unset | Node exclude list (`--exclude`) |
| `COMPUTE_MONITOR_GPUS_PER_NODE` | `1` | GPU count added automatically on GPU partitions |
| `COMPUTE_MONITOR_BIGMEM_MIN_MEMORY` | `1001G` | Memory added automatically on `bigmem*` partitions (allocate only) |
| `COMPUTE_MONITOR_STATE_FILE` | `~/.run/compute_monitor_jobs.tsv` | Tracks submitted allocate/cycle jobs |
| `COMPUTE_MONITOR_ALLOC_JOB_NAME_PREFIX` | `compute-monitor-alloc` | Prefix for submitted job names |

---

## Examples

```bash
# Cycle across the default four partitions, every 10 minutes
COMPUTE_MONITOR_CYCLE_INTERVAL=600 ./launch_monitor.sh cycle

# Continuous monitoring on a GPU partition for 4 hours
COMPUTE_MONITOR_PARTITION=gpu_h200 \
COMPUTE_MONITOR_TIME=04:00:00 \
./launch_monitor.sh allocate

# Attach to an existing job and snapshot every 30 seconds
COMPUTE_MONITOR_JOB_ID=123456 \
COMPUTE_MONITOR_INTERVAL=30 \
./launch_monitor.sh start

# Tail today's logs across all tracked jobs
./launch_monitor.sh tail
```

---

## Log Rotation

Logs accumulate indefinitely. To prune files older than 30 days:

```bash
find logs -name "*.log" -mtime +30 -delete
find logs -type d -empty -delete
```
