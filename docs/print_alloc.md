# print_alloc

Bash + awk over `scontrol`. Shows unallocated GPUs, CPUs, and memory per node in a partition (DOWN nodes omitted, sorted by most free resources first).

## Usage

```bash
print_alloc                          # default partition: gpu_requeue
print_alloc -p gpu_test
print_alloc -p gpu_requeue -a        # add CPULoad and UsedMem(GB)
print_alloc --help
```

## Options

| Flag | Description |
|------|-------------|
| `-p`, `--partition` | Partition name (default: `gpu_requeue`) |
| `-a`, `--available` | Extra columns: CPU load and used memory |
| `-h`, `--help` | Help |

## Columns

Default: `NodeName`, `UnallocGPU`, `UnallocCPU`, `UnallocMem(GB)`, `Gres`, `State`, `AllocTRES`.

With `-a`: also `CPULoad`, `UsedMem(GB)`.

Unallocated counts come from node capacity minus `AllocTRES`. GPU totals are parsed from `Gres` (`nvidia_*:N`).
