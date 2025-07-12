# SLURM Partition Optimizer

This Python script analyzes SLURM partition `TRESBillingWeights` and recommends the best partition to use based on your resource requirements.

## Features

- Parses `scontrol show partition` output to extract billing weights
- Calculates cost for different partitions based on CPU, memory, and GPU requirements
- Recommends the most cost-effective partition
- Filters partitions based on resource availability and time limits
- Provides suggested `sbatch` command
- Supports both human-readable and JSON output formats

## Requirements

- Python 3.6+
- SLURM environment with `scontrol` command available

## Usage

### Basic usage for CPU/Memory job:
```bash
python3 partition_optimizer.py --cpu 4 --mem 8
```

### For GPU jobs:
```bash
python3 partition_optimizer.py --cpu 8 --mem 16 --gpu 1
```

### With time limit:
```bash
python3 partition_optimizer.py --cpu 4 --mem 8 --time 96
```

### Show summary of all partitions:
```bash
python3 partition_optimizer.py --summary
```

### JSON output:
```bash
python3 partition_optimizer.py --cpu 4 --mem 8 --json
```

## Command-line Arguments

- `--cpu`: Number of CPUs required (required unless using --summary)
- `--mem`: Memory required in GB (required unless using --summary)
- `--gpu`: Number of GPUs required (default: 0)
- `--time`: Maximum time required in hours (optional)
- `--summary`: Show summary of all partitions (optional)
- `--json`: Output results in JSON format (optional)

## How It Works

1. **Data Collection**: Runs `scontrol show partition` to get partition information
2. **Parsing**: Extracts `TRESBillingWeights`, resource limits, and other metadata
3. **Filtering**: Removes partitions that cannot meet your requirements:
   - Insufficient CPUs, memory, or GPUs
   - Time limits shorter than required
   - Partitions not in "UP" state
4. **Cost Calculation**: Calculates billing cost using the formula:
   ```
   Cost = (CPU_count × CPU_weight) + (Memory_GB × Memory_weight) + (GPU_count × GPU_weight)
   ```
5. **Ranking**: Sorts partitions by cost (ascending) and priority tier (lower is better)

## Example Output

```bash
$ python3 partition_optimizer.py --cpu 4 --mem 8

Recommended partitions for your requirements:
  CPUs: 4
  Memory: 8.0 GB
  GPUs: 0

Rank Partition            Cost       Max Time        Priority Details
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