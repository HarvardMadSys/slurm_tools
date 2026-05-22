# Slurm tools

Small utilities for SLURM: partition recommendations from billing weights, allocation-style job submission, node resource tables, and per-job process monitoring.

## Requirements

- SLURM client tools (`sbatch`, `squeue`, `scontrol`).
- Bash for `best_partition`, `print_alloc`, and `slurm-alloc`.
- Python 3.6+ for `node_monitor` only (stdlib; needs SSH to compute nodes).

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

Adds to `~/.local/bin`: `best_partition`, `print_alloc`, `node_monitor`, `slurm-alloc`, `slurm-tools-upgrade`. Reload your shell or `source` the rc file `install.sh` updated.

```bash
best_partition --cpu 4 --mem 8
print_alloc -p gpu_requeue
node_monitor --job-id 12345
```

## Upgrade

```bash
slurm-tools-upgrade --check
slurm-tools-upgrade -y
```

Version is stored in `VERSION` at the install root. See `slurm-tools-upgrade --help` for `SLURM_TOOLS_ROOT`, `SLURM_TOOLS_BRANCH`, and `SLURM_TOOLS_REPO`.

## Tools

| Command | Script | Purpose |
|---------|--------|---------|
| `best_partition` | `best_partition.sh` | Recommend a partition from billing weights and available resources |
| `print_alloc` | `print_alloc.sh` | Table of unallocated GPU/CPU/memory per node |
| `slurm-alloc` | `alloc.sh` | Submit a placeholder job; auto-partition via `best_partition` when `-p best` |
| `node_monitor` | `dep/node_monitor.py` | SSH to job nodes and show your processes |
| `slurm-tools-upgrade` | `upgrade.sh` | Pull updates from GitHub |

## Quick start

```bash
best_partition --cpu 4 --mem 8
best_partition -n -c 4 -m 8 --gpu 1 --gpu-type h100   # partition name only
print_alloc -p gpu_requeue
print_alloc -p gpu_requeue -a                          # include CPU load / used memory
node_monitor --job-id 12345
slurm-alloc -c 16 -m 256 -g 1 -u h100                  # site-specific; see below
```

## Docs

| Tool | Doc |
|------|-----|
| `best_partition` | [docs/best_partition.md](docs/best_partition.md) |
| `print_alloc` | [docs/print_alloc.md](docs/print_alloc.md) |
| `slurm-alloc` | [docs/alloc.sh.md](docs/alloc.sh.md) |
| `node_monitor` | [dep/node_monitor.md](dep/node_monitor.md) |

## Notes on `slurm-alloc`

`alloc.sh` contains cluster-specific paths (sleep script, log dirs, node name checks). Edit before use on another site.

On each run, `slurm-alloc` may auto-upgrade from GitHub (at most once per 24h). Disable with `SLURM_TOOLS_SKIP_UPGRADE=1`; force a check with `SLURM_TOOLS_FORCE_UPGRADE_CHECK=1`.
