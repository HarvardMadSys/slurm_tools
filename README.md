# Slurm tools

Small utilities for SLURM, exposed as a single `st` command: partition recommendations from billing weights, allocation-style job submission, node resource tables, and per-job process monitoring.

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
./install.sh
./install.sh --dry-run   # preview only
```

Installs a single command, `st`, into `~/.local/bin`. Reload your shell or `source` the rc file `install.sh` updated, then run `st help` to list subcommands.

```bash
st partition -c 4 -m 8
st nodes -p gpu_requeue
st monitor 12345
```

## Upgrade

```bash
st upgrade --check
st upgrade -y
```

Version is stored in `VERSION` at the install root. Upgrades replace the install tree (`rsync --delete` when available); a git checkout used as `SLURM_TOOLS_ROOT` may lose `.git`. See `st upgrade --help` for `SLURM_TOOLS_ROOT`, `SLURM_TOOLS_BRANCH`, and `SLURM_TOOLS_REPO`.

## Commands

`st` dispatches to one subcommand per tool. Flags mirror `sbatch` where they overlap (`-N` nodes, `-J` job-name, `-c` cpus, `-G` gpu-type, `-t` time, `-p` partition); every flag has a long form too.

| Command | Script | Purpose |
|---------|--------|---------|
| `st alloc` | `alloc.sh` | Submit a placeholder job; auto-partition via `st partition` when `-p best` |
| `st submit` | `submit_job.sh` | Submit your batch script with the same flags; prints job ID |
| `st partition` | `best_partition.sh` | Recommend a partition from billing weights and available resources |
| `st nodes` | `print_alloc.sh` | Table of unallocated GPU/CPU/memory per node |
| `st monitor` | `dep/node_monitor.py` | SSH to a job's nodes and show your processes |
| `st upgrade` | `upgrade.sh` | Pull updates from GitHub |

## Quick start

```bash
st partition -c 4 -m 8
st partition -c 4 -m 8 -g 1 -G h100 --name-only   # partition name only
st nodes -p gpu_requeue
st nodes -p gpu_requeue -a                          # include CPU load / used memory
st monitor 12345
st monitor 12345 --json | jq .                      # progress on stderr
st alloc -c 16 -m 256 -g 1 -G h100
st submit -c 16 -m 256 -g 1 -G h100 train.sh
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
| `st partition` | [docs/best_partition.md](docs/best_partition.md) |
| `st nodes` | [docs/print_alloc.md](docs/print_alloc.md) |
| `st alloc` | [docs/alloc.sh.md](docs/alloc.sh.md) |
| `st submit` | [docs/submit_job.md](docs/submit_job.md) |
| `st monitor` | [dep/node_monitor.md](dep/node_monitor.md) |
| environment variables | [docs/env.md](docs/env.md) |

## Notes on `st alloc`

`alloc.sh` uses a cluster-specific default for the placeholder sleep script. Set `SLURM_TOOLS_ALLOC_SCRIPT` on other sites.

On each run, `st alloc` may auto-upgrade from GitHub (at most once per 24h). Disable with `SLURM_TOOLS_SKIP_UPGRADE=1`; force a check with `SLURM_TOOLS_FORCE_UPGRADE_CHECK=1`.
