# print-alloc

Bash + awk over `scontrol`. Shows unallocated GPUs, CPUs, and memory per node in a partition (DOWN nodes omitted, sorted by most free resources first).

## Usage

```bash
print-alloc
print-alloc -p gpu_test
print-alloc -p gpu_requeue -a
print-alloc --help
```

## Options

| Flag | Description |
|------|-------------|
| `-p`, `--partition` | Partition (default: `SLURM_TOOLS_DEFAULT_PARTITION` or `gpu_requeue`) |
| `-a`, `--available` | Extra columns: CPU load and used memory |
| `-h`, `--help` | Help |

## Columns

Default: `NodeName`, `UnallocGPU`, `UnallocCPU`, `UnallocMem(GB)`, `Gres`, `State`, `AllocTRES`.

With `-a`: also `CPULoad`, `UsedMem(GB)`.

Unallocated counts come from node capacity minus `AllocTRES`. GPU totals are parsed from `Gres`.
