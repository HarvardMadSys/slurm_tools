# Slurm tools

Small utilities for SLURM, exposed as a single `st` command: partition recommendations from billing weights, allocation-style job submission, node resource tables, and per-job process monitoring. 

## Features
- **Partition recommendations**: `st partition` recommends a partition based on billing weights and available resources, with filters for GPU type and other features. **This is useful for reducing wait time and cost**.
- **Allocation-style job submission**: `st alloc` and `st submit` allocate a node from the best partition and submit a job to it in one step, with an optional placeholder sleep script for interactive use. **This is useful for quickly starting jobs on low-cost partitions**.

## Requirements

- SLURM client tools (`sbatch`, `squeue`, `scontrol`).
- Bash for `st` and all subcommands except `monitor`.
- Python 3.7+ for `st monitor` only (stdlib; needs SSH to compute nodes).

## Install

```bash
mkdir -p ~/.local/share/slurm_tools && curl -fsSL https://codeload.github.com/HarvardMadSys/slurm_tools/tar.gz/main | tar -xz --strip-components=1 -C ~/.local/share/slurm_tools && ~/.local/share/slurm_tools/install.sh
```


## Commands

`st` dispatches to one subcommand per tool. Flags mirror `sbatch` where they overlap (`-N` nodes, `-J` job-name, `-c` cpus, `-G` gpu-type, `-t` time, `-p` partition); every flag has a long form too. Use `-x`/`--exclude` on any command to skip specific partitions from auto-selection.

| Command | Script | Purpose |
|---------|--------|---------|
| `st alloc` | `libexec/alloc.sh` | Allocate a node from the best partition e.g., immediately available and lowest cost |
| `st submit` | `libexec/submit.sh` | Submit job to the best partition, e.g., immediately available and lowest cost |
| `st partition` | `libexec/partition.sh` | Recommend a partition from billing weights and available resources |
| `st nodes` | `libexec/nodes.sh` | Table of unallocated GPU/CPU/memory per node (used for manual allocation) |
| `st monitor` | `libexec/monitor.py` | SSH to a job's nodes and show your processes |
| `st upgrade` | `libexec/upgrade.sh` | Pull updates from GitHub |

## Quick start

```bash
# allocate an interactive job on the best partition for a GPU job needing 16 CPUs and 256GB memory on H100s
st alloc -c 16 -m 256 -g 1 -G h100
# submit a batch job to the best partition for a GPU job needing 16 CPUs and 256GB memory on H100s
st submit -c 16 -m 256 -g 1 -G h100 train.sh
# find the best partition for a GPU job needing 4 CPUs and 8GB memory
st partition -c 4 -m 8
# find the best partition for a GPU job needing 4 CPUs and 8GB memory on H100s
st partition -c 4 -m 8 -g 1 -G h100 --name-only   # partition name only
# exclude specific partitions from auto-selection
st partition -c 16 -m 64 -g 1 -G h200 --exclude gpu_h200
st alloc -g 1 -G h200 --exclude seas_gpu,gpu_h200
# list the available resources on each node in the gpu_requeue partition
st nodes -p gpu_requeue
st monitor 12345 --json | jq .                      # progress on stderr
```

## Docs

| Tool | Doc |
|------|-----|
| `st partition` | [docs/partition.md](docs/partition.md) |
| `st nodes` | [docs/nodes.md](docs/nodes.md) |
| `st alloc` | [docs/alloc.md](docs/alloc.md) |
| `st submit` | [docs/submit.md](docs/submit.md) |
| `st monitor` | [docs/monitor.md](docs/monitor.md) |
| environment variables | [docs/env.md](docs/env.md) |

