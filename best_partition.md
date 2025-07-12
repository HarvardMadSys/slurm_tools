# SLURM Partition Optimizer

This Python script analyzes SLURM partition `TRESBillingWeights` and recommends the best partition to use based on your resource requirements.

**By default, it uses available (unallocated) resources for more realistic recommendations.** Use `--total-resources` to use total partition capacity instead.

## Features

- Parses `scontrol show partition` output to extract billing weights
- Calculates cost for different partitions based on CPU, memory, and GPU requirements
- Recommends the most cost-effective partition
- Filters partitions based on resource availability and time limits
- **Available Resources by Default**: Uses currently available (unallocated) resources for more realistic recommendations
- Provides suggested `sbatch` command
- Supports both human-readable and JSON output formats

## Requirements

- Python 3.6+
- SLURM environment with `scontrol` command available

## Usage

### Basic usage for CPU/Memory job (uses available resources by default):
```bash
python3 best_partition.py --cpu 4 --mem 8
```

### For GPU jobs (uses available resources by default):
```bash
python3 best_partition.py --cpu 8 --mem 16 --gpu 1
```

### With time limit:
```bash
python3 best_partition.py --cpu 4 --mem 8 --time 96
```

### Show summary of all partitions (shows available resources by default):
```bash
python3 best_partition.py --summary
```

### Use total resources instead of available resources:
```bash
python3 best_partition.py --cpu 4 --mem 8 --gpu 1 --total-resources
```

### Show summary with total resources:
```bash
python3 best_partition.py --summary --total-resources
```

### JSON output (includes available resources by default):
```bash
python3 best_partition.py --cpu 4 --mem 8 --json
```

### JSON output with total resources:
```bash
python3 best_partition.py --cpu 4 --mem 8 --total-resources --json
```

## Command-line Arguments

- `--cpu`: Number of CPUs required (required unless using --summary)
- `--mem`: Memory required in GB (required unless using --summary)
- `--gpu`: Number of GPUs required (default: 0)
- `--time`: Maximum time required in hours (optional)
- `--summary`: Show summary of all partitions (optional)
- `--json`: Output results in JSON format (optional)
- `--total-resources`: Use total resources instead of available resources for filtering and display (optional)

## How It Works

1. **Data Collection**: Runs `scontrol show partition` to get partition information
2. **Resource Fetching** (default): Queries `scontrol show node` to determine currently available resources
3. **Parsing**: Extracts `TRESBillingWeights`, resource limits, and other metadata
4. **Filtering**: Removes partitions that cannot meet your requirements:
   - Insufficient CPUs, memory, or GPUs (available by default, or total if `--total-resources` is used)
   - Time limits shorter than required
   - Partitions not in "UP" state
5. **Cost Calculation**: Calculates billing cost using the formula:
   ```
   Cost = (CPU_count × CPU_weight) + (Memory_GB × Memory_weight) + (GPU_count × GPU_weight)
   ```
6. **Ranking**: Sorts partitions by cost (ascending) and priority tier (lower is better)

## Available vs Total Resources

### Available Resources Mode (Default)
- Uses currently unallocated resources (Total - Allocated)
- Shows what's actually available for immediate use
- Provides more realistic recommendations based on current cluster state
- Filters out partitions that don't have enough available resources right now

### Total Resources Mode (`--total-resources`)
- Uses the total capacity of each partition
- Shows theoretical maximum resources
- May recommend partitions that appear to have capacity but are actually fully utilized
- Useful for planning or understanding partition limits

## Example Output

### Basic Usage (Available Resources - Default)
```bash
$ python3 best_partition.py --cpu 4 --mem 8 --gpu 1

Recommended partitions for your requirements (using available resources):
  CPUs: 4
  Memory: 8.0 GB
  GPUs: 1

Rank Partition            Cost       Max Time        Priority Available Resources
-------------------------------------------------------------------------------------
1    gpu_test             0.000      12:00:00        4        620 CPUs, 4308 GB, 81 GPUs
2    serial_requeue       107.600    3-00:00:00      1        22468 CPUs, 364341 GB, 285 GPUs
3    gpu_requeue          107.600    3-00:00:00      2        7614 CPUs, 174125 GB, 285 GPUs

🎯 Best recommendation: gpu_test
   Cost: 0.000 billing units
   Max time: 12:00:00
   Priority tier: 4
   Billing weights: {'CPU': 0.0, 'Mem': 0.0, 'Gres/gpu': 0.0}
   Available resources: 620 CPUs, 4308.5 GB RAM, 81 GPUs

📋 Suggested sbatch command:
   sbatch --partition=gpu_test --cpus-per-task=4 --mem=8G --gres=gpu:1 your_script.sh
```

### Total Resources Mode
```bash
$ python3 best_partition.py --cpu 4 --mem 8 --total-resources

Recommended partitions for your requirements (using total resources):
  CPUs: 4
  Memory: 8.0 GB
  GPUs: 0

Rank Partition            Cost       Max Time        Priority Total Resources
-------------------------------------------------------------------------------------
1    gpu_test             0.000      12:00:00        4        896 CPUs, 7042 GB, 112 GPUs
2    test                 0.000      12:00:00        5        2016 CPUs, 18126 GB
3    bigmem               2.640      3-00:00:00      3        448 CPUs, 8060 GB

🎯 Best recommendation: gpu_test
   Cost: 0.000 billing units
   Max time: 12:00:00
   Priority tier: 4
   Billing weights: {'CPU': 0.0, 'Mem': 0.0, 'Gres/gpu': 0.0}

📋 Suggested sbatch command:
   sbatch --partition=gpu_test --cpus-per-task=4 --mem=8G your_script.sh
```

### Summary with Available Resources (Default)
```bash
$ python3 best_partition.py --summary

Partition            CPU Weight Mem Weight GPU Weight Max Time        State    Avail CPUs      Avail Mem(GB)   Avail GPUs
----------------------------------------------------------------------------------------------------------------------------
gpu_test             0.000      0.000      0.000      12:00:00        UP       620             4308.5          81
gpu                  1.150      0.070      209.100    3-00:00:00      UP       219             18305.5         5
seas_gpu             0.900      0.060      333.200    7-00:00:00      UP       1965            32433.5         34
```

## Understanding TRESBillingWeights

TRESBillingWeights determine how much you're charged for using different resources:
- `CPU=0.6`: Each CPU costs 0.6 billing units
- `Mem=0.07G`: Each GB of memory costs 0.07 billing units  
- `Gres/gpu=209.1`: Each GPU costs 209.1 billing units

The script helps you find the partition with the lowest total cost for your specific requirements.

## Notes

- The script prioritizes cost-effectiveness over other factors
- Free partitions (`test`, `gpu_test`) are ranked highest if they meet your requirements
- Consider queue wait times and priority - sometimes a slightly more expensive partition with better priority may be worth it
- For production workloads, avoid test partitions which typically have short time limits
- **Available resources mode is the default** - it shows what's actually available right now rather than theoretical capacity
- Available resources mode is particularly useful during busy periods when many partitions may appear to have capacity but are actually fully utilized
- Use `--total-resources` when you need to see partition limits for planning purposes or when available resources aren't relevant 