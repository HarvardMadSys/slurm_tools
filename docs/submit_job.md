# submit_job.sh - SLURM job submission

## Overview

Submit a batch script with the same resource flags and auto-partition logic as `slurm-alloc`, but without waiting for the job to start. Prints the job ID and exits.

## Basic usage

```bash
# Defaults: 16 CPUs, 256GB RAM, 1× h100, 12h, partition from best_partition
slurm-submit train.sh

slurm-submit -c 32 -m 512 -g 2 -u a100 -t 24 run.sh --config cfg.yaml
slurm-submit -c 8 -m 64 -g 0 -p serial cpu_job.sh
```

## Parameters

| Flag | Parameter | Default | Description |
|------|-----------|---------|-------------|
| `-j` | JOB_NAME | derived | Job name |
| `-c` | CPU_CORE | `16` | CPU cores |
| `-m` | MEM_GB | `256` | Memory (GB) |
| `-u` | GPU_TYPE | `h100` | GPU short name (see `alloc.sh`) |
| `-g` | GPU_COUNT | `1` | GPUs (`0` for CPU-only) |
| `-t` | TIMEOUT_HOURS | `12` | Wall time (hours) |
| `-p` | PARTITION | `best` | Partition or `best` for `best_partition` |
| `-v` | | | Show version |
| `-h` | | | Help |

Positional arguments: `SCRIPT` (required), then any arguments passed through to the batch script.

## Notes

- Requires `best_partition` in PATH when `-p best`.
- Writes `logs/%x.%j.out` and `logs/%x.%j.err` under the current directory.
- Same optional auto-upgrade behavior as `slurm-alloc` (`SLURM_TOOLS_SKIP_UPGRADE`, `SLURM_TOOLS_FORCE_UPGRADE_CHECK`).
