# st alloc - SLURM GPU allocation script

## Overview

Interactive SLURM job allocation: auto-partition via `st partition`, submit a placeholder job, wait until it is running on a valid node, then record the hostname under `~/.alloc/`.

## Basic usage

```bash
st alloc
st alloc -c 32 -m 512 -g 2 -G a100
st alloc -c 16 -m 128 -g 1 -G h100 -p gpu_requeue
```

## Parameters

Flags mirror `sbatch` (`-N` nodes, `-J` job-name, `-c` cpus); each has a long form.

| Flag | Parameter | Default | Description |
|------|-----------|---------|-------------|
| `-J, --job-name` | JOB_NAME | derived | `whoami` if `-g 0`, else `${GPUS}${GPU_TYPE}` (`${GPUS}gpu` when no type) |
| `-N, --nodes` | NODES | `1` | Number of nodes |
| `-c, --cpus` | CPUS | `16` | CPU cores per node |
| `-m, --mem` | MEM_GB | `256` | Memory per node (GB) |
| `-G, --gpu-type` | GPU_TYPE | any | Short GPU name (see below); omit to allow any GPU type |
| `-g, --gpus` | GPUS | `1` | GPUs per node (`0` for CPU-only) |
| `-t, --time` | HOURS | `12` | Wall time (hours; `>23` becomes `D-HH:00:00`) |
| `-p, --partition` | PARTITION | `best` | Partition or `best` for `st partition` |
| `--version` | | | Show version |
| `-h, --help` | | | Help |

## GPU types

| Short name | SLURM gres name |
|------------|-----------------|
| `h100` | `nvidia_h100_80gb_hbm3` |
| `h200` | `nvidia_h200` |
| `a100`, `a100-80gb` | `nvidia_a100-sxm4-80gb` |
| `a100-40gb` | `nvidia_a100-sxm4-40gb` |
| `a40` | `nvidia_a40` |
| `a100mig` | `nvidia_a100_3g.20gb` (partition `gpu_test` unless `SLURM_TOOLS_MIG_PARTITION` set) |

## Site environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `SLURM_TOOLS_ALLOC_SCRIPT` | Harvard lab sleep script | Batch script to run |
| `SLURM_TOOLS_MIG_PARTITION` | `gpu_test` | Partition for `-G a100mig` with `-p best` |
| `SLURM_TOOLS_SKIP_UPGRADE` | | `1` disables auto-upgrade |
| `SLURM_TOOLS_FORCE_UPGRADE_CHECK` | | `1` forces version check |

## Behavior

- Creates `logs/` before submit; checks `sbatch` exit status.
- Waits using `scontrol` job state; exits on `FAILED`, `CANCELLED`, `TIMEOUT`, etc.
- Ctrl+C runs `scancel` only if a job ID was obtained.
- Writes `~/.alloc/${JOB_NAME}` with the first allocated node name.

## Partition selection (`-p best`)

`-c/-m/-g` are per-node; totals (`cpu*nodes`, `mem*nodes`, `gpu*nodes`) are passed to `st partition`.

1. First pass uses currently **available** resources (`st partition --name-only`).
2. If nothing fits, falls back to **total** capacity (`st partition --name-only --total`); the job will queue. A warning is logged to stderr:
   `warning: no partition has enough free resources right now; retrying against total capacity`
   `warning: <partition> may be fully allocated; job will queue`
3. If neither pass finds a partition, exits with `No suitable partitions found for your requirements.`

`-G a100mig` with `-p best` short-circuits to `$SLURM_TOOLS_MIG_PARTITION` (default `gpu_test`).

## Examples

```bash
st alloc -g 1
st alloc -c 32 -m 1024 -g 2 -G a100 -t 24
st alloc -N 4 -c 64 -m 512 -g 4 -G h200 -t 48   # 4-node h200 job
export SLURM_TOOLS_ALLOC_SCRIPT=/path/to/sleep.sh
st alloc -c 8 -m 64 -g 0 -t 4
```

`~/.alloc/<JOB_NAME>` contains the full SLURM NodeList string (e.g. `node[01-04]`), usable directly with `srun --nodelist`.
