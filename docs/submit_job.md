# slurm-submit - SLURM job submission

## Overview

Submit a batch script with the same resource flags and auto-partition logic as `slurm-alloc`, without waiting for the job to start. Prints the job ID and exits.

## Basic usage

```bash
slurm-submit train.sh
slurm-submit -c 32 -m 512 -g 2 -u a100 -t 24 run.sh --config cfg.yaml
slurm-submit -n 4 -c 64 -m 512 -g 4 -u h200 -t 48 train.sh   # 4-node h200 job
slurm-submit -c 8 -m 64 -g 0 -p serial cpu_job.sh
```

## Parameters

| Flag | Parameter | Default | Description |
|------|-----------|---------|-------------|
| `-j` | JOB_NAME | derived | Same rules as `slurm-alloc` |
| `-n` | NODES | `1` | Number of nodes |
| `-c` | CPU_CORE | `16` | CPU cores per node |
| `-m` | MEM_GB | `256` | Memory per node (GB) |
| `-u` | GPU_TYPE | any | Short GPU name (see [alloc.sh.md](alloc.sh.md)); omit to allow any GPU type |
| `-g` | GPU_COUNT | `1` | GPUs per node (`0` for CPU-only) |
| `-t` | TIMEOUT_HOURS | `12` | Wall time (hours) |
| `-p` | PARTITION | `best` | Partition or `best` |
| `-v` | | | Show version |
| `-h` | | | Help |

Positional: `SCRIPT` (optional), then arguments passed to the batch script. If `SCRIPT` is omitted, slurm-submit generates a placeholder script that sleeps 7 days (held at `~/.cache/slurm_tools/dummy_sleep.sh`) and submits that instead — useful for grabbing an allocation you'll log in to. In this case slurm-submit then **waits** for the job to start (like `slurm-alloc`) and prints the allocated node hostnames plus a ready-to-use `ssh <host>` line for each; you can also `srun --jobid <job_id> --pty bash`. Ctrl+C stops waiting without cancelling the job. Slurm kills the placeholder at the job time limit (`-t`).

When `SCRIPT` is provided, behaviour is unchanged: slurm-submit prints the job ID and exits without waiting.

## Notes

- Requires `best_partition` in PATH when `-p best`.
- Creates `logs/` and validates `sbatch` success.
- Same auto-upgrade env vars as `slurm-alloc` (`SLURM_TOOLS_SKIP_UPGRADE`, etc.).
- Shared helpers live in `lib/slurm_common.sh`.

## Partition selection (`-p best`)

`-c/-m/-g` are per-node; totals across nodes are passed to `best_partition`. Selection first tries currently **available** resources, then falls back to **total** capacity (job will queue). Fallback warnings go to stderr, e.g.:

```
warning: no partition has enough free resources right now; retrying against total capacity
warning: gpu_h200 may be fully allocated; job will queue
```

See [alloc.sh.md](alloc.sh.md#partition-selection--p-best) for full details.
