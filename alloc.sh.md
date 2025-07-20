# alloc.sh - SLURM GPU Allocation Script

## Overview
Interactive SLURM job allocation script that automatically finds the best partition and waits for resource allocation. Supports GPU allocation with simplified GPU type names.

## Basic Usage
```bash
# Use defaults (16 CPUs, 256GB RAM, h100 GPU, auto-partition)
./alloc.sh

# Specify resources
./alloc.sh -c 32 -m 512 -g 2 -u a100

# Specify partition manually
./alloc.sh -c 16 -m 128 -g 1 -u h100 -p gpu_requeue
```

## Parameters
| Flag | Parameter | Default | Description |
|------|-----------|---------|-------------|
| `-j` | JOB_NAME | `h100_$(whoami)` | Job name |
| `-c` | CPU_CORE | `16` | Number of CPU cores |
| `-m` | MEM_GB | `256` | Memory in GB |
| `-u` | GPU_TYPE | `h100` | GPU type (see below) |
| `-g` | GPU_COUNT | `0` | Number of GPUs |
| `-t` | TIMEOUT_HOURS | `12` | Job timeout in hours |
| `-p` | PARTITION | `best` | Partition name |
| `-h` | | | Show help |

## GPU Types
| Short Name | Full SLURM Name |
|------------|------------------|
| `h100` | `nvidia_h100_80gb_hbm3` |
| `a100` | `nvidia_a100-sxm4-80gb` |
| `a100-80gb` | `nvidia_a100-sxm4-80gb` |
| `a100-40gb` | `nvidia_a100-sxm4-40gb` |
| `a40` | `nvidia_a40` |
| `h200` | `nvidia_h200` |

## Features
- **Auto-partition selection**: Uses `best_partition` script when `-p best` (default)
- **Interactive waiting**: Shows progress dots while waiting for allocation
- **Ctrl+C handling**: Automatically cancels job on interrupt
- **Time format handling**: Supports timeouts > 24 hours (converts to days-hours format)

## Examples
```bash
# Quick H100 allocation
./alloc.sh -g 1

# Large memory job with A100
./alloc.sh -c 32 -m 1024 -g 2 -u a100 -t 24

# Specific partition (skip auto-selection)
./alloc.sh -c 8 -m 64 -g 1 -u a40 -p gpu_test

# Long-running job (48 hours)
./alloc.sh -c 16 -m 256 -g 1 -u h100 -t 48
```

## Notes
- Requires `best_partition` script in PATH for auto-partition selection
- Creates log files in `logs/` directory (`%x.%j.out`, `%x.%j.err`)
- Waits until job starts and shows allocated server name
- Script exits when resources are successfully allocated 