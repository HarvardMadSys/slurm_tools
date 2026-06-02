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

**Without cloning** (installs to `~/.local/share/slurm_tools`; keep that directory):

```bash
mkdir -p ~/.local/share/slurm_tools && curl -fsSL https://codeload.github.com/HarvardMadSys/slurm_tools/tar.gz/main | tar -xz --strip-components=1 -C ~/.local/share/slurm_tools && ~/.local/share/slurm_tools/install.sh
```

**From a clone:**

```bash
# Installs a single command, `st`, into `~/.local/bin`. Reload your shell or `source` the rc file `install.sh` updated, then run `st help` to list subcommands.
./install.sh
```



Version is stored in `VERSION` at the install root. Upgrades replace the install tree (`rsync --delete` when available); a git checkout used as `SLURM_TOOLS_ROOT` may lose `.git`. See `st upgrade --help` for `SLURM_TOOLS_ROOT`, `SLURM_TOOLS_BRANCH`, and `SLURM_TOOLS_REPO`.

## Commands

`st` dispatches to one subcommand per tool. Flags mirror `sbatch` where they overlap (`-N` nodes, `-J` job-name, `-c` cpus, `-G` gpu-type, `-t` time, `-p` partition); every flag has a long form too.

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
# list the available resources on each node in the gpu_requeue partition
st nodes -p gpu_requeue
st monitor 12345 --json | jq .                      # progress on stderr
```

## Site configuration

Defaults target a Harvard FASRC-style cluster. Override with environment variables — see [docs/env.md](docs/env.md) for full details.

| Variable | Used by | Default |
|----------|---------|---------|
| `SLURM_TOOLS_ALLOC_SCRIPT` | `st alloc` | Harvard lab sleep script |
| `SLURM_TOOLS_DEFAULT_PARTITION` | `st nodes` | `gpu_requeue` |
| `SLURM_TOOLS_MIG_PARTITION` | `st alloc`, `st submit` | `gpu_test` |
| `SLURM_TOOLS_SKIP_PARTITIONS_GPU_JOB` | `st partition` | `serial_requeue` |
| `SLURM_TOOLS_SKIP_PARTITIONS_CPU_JOB` | `st partition` | `gpu_requeue gpu_test` |
| `SLURM_TOOLS_SKIP_UPGRADE` | `st alloc`, `st submit` | unset |
| `SLURM_TOOLS_FORCE_UPGRADE_CHECK` | `st alloc`, `st submit` | unset |

## Docs

| Tool | Doc |
|------|-----|
| `st partition` | [docs/partition.md](docs/partition.md) |
| `st nodes` | [docs/nodes.md](docs/nodes.md) |
| `st alloc` | [docs/alloc.md](docs/alloc.md) |
| `st submit` | [docs/submit.md](docs/submit.md) |
| `st monitor` | [docs/monitor.md](docs/monitor.md) |
| environment variables | [docs/env.md](docs/env.md) |

## Notes on `st alloc`

`libexec/alloc.sh` uses a cluster-specific default for the placeholder sleep script. Set `SLURM_TOOLS_ALLOC_SCRIPT` on other sites.

On each run, `st alloc` may auto-upgrade from GitHub (at most once per 24h). Disable with `SLURM_TOOLS_SKIP_UPGRADE=1`; force a check with `SLURM_TOOLS_FORCE_UPGRADE_CHECK=1`.
