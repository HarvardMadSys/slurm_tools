# Slurm tools

Small utilities for working with SLURM: picking a partition from billing weights, submitting allocation-style jobs, printing free resources on GPU nodes, and inspecting processes on job nodes.

## Requirements

- A working SLURM environment (`sbatch`, `squeue`, `scontrol`).
- Python 3.6+ for the Python scripts (`python3` in examples).
- Optional: SSH access from the submission host to compute nodes (`dep/node_monitor.py`).

Dependencies are Python standard library only.

## Install

**Without cloning** (downloads a tarball into `~/.local/share/slurm_tools`; keep that directory—`~/.local/bin` symlinks point into it):

```bash
mkdir -p ~/.local/share/slurm_tools && curl -fsSL https://codeload.github.com/HarvardMadSys/slurm_tools/tar.gz/main | tar -xz --strip-components=1 -C ~/.local/share/slurm_tools && ~/.local/share/slurm_tools/install.sh
```

After installation, reload your shell (or open a new terminal) and try:

```bash
source ~/.zshrc   # zsh; use ~/.bashrc for bash, or the rc file install.sh mentioned

best_partition --cpu 4 --mem 8
print_alloc -p gpu_requeue
```

To preview without applying changes, run `install.sh --dry-run` (from a clone as `./install.sh`, or `~/.local/share/slurm_tools/install.sh` after the one-liner above).

**From a local clone** of this repository:

```bash
./install.sh          # symlinks into ~/.local/bin, updates shell rc for $SHELL
./install.sh --dry-run
```

Commands added: `best_partition`, `print_alloc`, `node_monitor`, `slurm-alloc` (symlink to `alloc.sh`), `slurm-tools-upgrade`. Reload your shell or `source ~/.zshrc` (or the file the script reported).

## Upgrade

Installed version is stored in `VERSION` at the install root (e.g. `~/.local/share/slurm_tools/VERSION`). To compare with [GitHub `main`](https://github.com/HarvardMadSys/slurm_tools) and upgrade:

```bash
slurm-tools-upgrade --check    # exit 1 if a newer version is available
slurm-tools-upgrade            # interactive upgrade
slurm-tools-upgrade -y         # upgrade without prompting
slurm-tools-upgrade --dry-run  # preview steps
slurm-tools-upgrade --version  # print installed version
```

Override install location or branch:

```bash
SLURM_TOOLS_ROOT=~/.local/share/slurm_tools SLURM_TOOLS_BRANCH=main slurm-tools-upgrade -y
```

If your default shell differs from the one you use in the terminal, add to that rc file manually:

```bash
case ":${PATH}:" in
  *:"${HOME}/.local/bin":*) ;;
  *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac
```

## Scripts

| File | Purpose |
|------|---------|
| `best_partition.py` | Score partitions using `TRESBillingWeights`, filter by limits and **available** resources (by default), print a suggestion or `--name-only` for shell use. |
| `alloc.sh` | Wrapper: optional auto-partition via `best_partition`, then `sbatch` with simplified GPU names and waits until the job lands on a node. **Site-specific** paths inside (see below). |
| `print_alloc.py` | Table of nodes in a partition: unallocated GPUs/CPUs/memory; `-a` adds load and memory detail. Default partition is `gpu_requeue` (override with `-p`). |
| `dep/node_monitor.py` | Given a SLURM job ID, resolve node list and SSH to each host to show per-user CPU/RAM/process list; optional `--json` and `--proc` filter. |

## Quick start

```bash
# Recommend a partition for 4 CPUs, 8 GB RAM (uses available capacity by default)
python3 best_partition.py --cpu 4 --mem 8

# Partition name only (e.g. for scripts)
python3 best_partition.py -n -c 4 -m 8 --gpu 1 --gpu-type h100

# Free resources on nodes (adjust partition for your cluster)
python3 print_alloc.py -p your_gpu_partition

# Processes on nodes for job 12345 (needs SSH)
python3 dep/node_monitor.py --job-id 12345
```

`alloc.sh` / `slurm-alloc` expects `best_partition` on `PATH` when using `-p best` (handled by `./install.sh`).

See [docs/best_partition.md](docs/best_partition.md) for CLI flags, GPU filters, JSON output, and `--total-resources`.

## Documentation

| Topic | Doc |
|-------|-----|
| `best_partition.py` | [docs/best_partition.md](docs/best_partition.md) |
| `alloc.sh` | [docs/alloc.sh.md](docs/alloc.sh.md) |
| `print_alloc.py` | [print_alloc.md](print_alloc.md) *(default partition name may differ from the script; check `python3 print_alloc.py --help`)* |
| `dep/node_monitor.py` | [dep/node_monitor.md](dep/node_monitor.md) |

## Notes on `alloc.sh`

The script submits a placeholder job (`sleep.sh`), mail notifications, log paths under `logs/`, and may reference cluster-specific paths inside the repo file. Tailor those lines before use on another site.
