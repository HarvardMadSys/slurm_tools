# st submit - SLURM job submission

## Overview

Submit a batch script with the same resource flags and auto-partition logic as `st alloc`, without waiting for the job to start. Prints the job ID and exits.

## Basic usage

```bash
st submit train.sh
st submit -c 32 -m 512 -g 2 -G a100 -t 24 run.sh --config cfg.yaml
st submit -N 4 -c 64 -m 512 -g 4 -G h200 -t 48 train.sh   # 4-node h200 job
st submit -c 8 -m 64 -g 0 -p serial cpu_job.sh
```

## Parameters

Flags mirror `sbatch` (`-N` nodes, `-J` job-name, `-c` cpus); each has a long form.

| Flag | Parameter | Default | Description |
|------|-----------|---------|-------------|
| `-J, --job-name` | JOB_NAME | derived | Same rules as `st alloc` |
| `-N, --nodes` | NODES | `1` | Number of nodes |
| `-c, --cpus` | CPUS | `16` | CPU cores per node |
| `-m, --mem` | MEM_GB | `256` | Memory per node (GB) |
| `-G, --gpu-type` | GPU_TYPE | any | Short GPU name (see [alloc.md](alloc.md)); omit to allow any GPU type |
| `-g, --gpus` | GPUS | `1` | GPUs per node (`0` for CPU-only) |
| `-t, --time` | HOURS | `12` | Wall time (hours) |
| `-p, --partition` | PARTITION | `best` | Partition or `best` |
| `--version` | | | Show version |
| `-h, --help` | | | Help |

Positional: `SCRIPT` (optional), then arguments passed to the batch script. If `SCRIPT` is omitted, st submit generates a placeholder script that sleeps 7 days (held at `~/.cache/slurm_tools/dummy_sleep.sh`) and submits that instead — useful for grabbing an allocation you'll log in to. In this case st submit then **waits** for the job to start (like `st alloc`) and prints the allocated node hostnames plus a ready-to-use `ssh <host>` line for each; you can also `srun --jobid <job_id> --pty bash`. Ctrl+C stops waiting without cancelling the job. Slurm kills the placeholder at the job time limit (`-t`).

When `SCRIPT` is provided, behaviour is unchanged: st submit prints the job ID and exits without waiting.

## Notes

- Resolves the partition with the same logic as `st partition` when `-p best` (runs the bundled `libexec/partition.sh`).
- Creates `logs/` and validates `sbatch` success.
- Same auto-upgrade env vars as `st alloc` (`SLURM_TOOLS_SKIP_UPGRADE`, etc.).
- Shared helpers live in `lib/slurm_common.sh`.

## Partition selection (`-p best`)

`-c/-m/-g` are per-node; totals across nodes are passed to `st partition`. Selection first tries currently **available** resources, then falls back to **total** capacity (job will queue). Fallback warnings go to stderr, e.g.:

```
warning: no partition has enough free resources right now; retrying against total capacity
warning: gpu_h200 may be fully allocated; job will queue
```

See [alloc.md](alloc.md#partition-selection--p-best) for full details.
