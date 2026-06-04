# SLURM Partition Optimizer

This tool analyzes SLURM partition `TRESBillingWeights` and recommends the best partition to use based on your resource requirements.

**By default, it uses available (unallocated) resources for more realistic recommendations.** Use `--total` to use total partition capacity instead.

## Features

- Parses `scontrol show partition` output to extract billing weights
- Calculates cost for different partitions based on CPU, memory, and GPU requirements
- Recommends the most cost-effective partition
- Filters partitions based on resource availability and time limits
- **Available Resources by Default**: Uses currently available (unallocated) resources for more realistic recommendations
- Provides suggested `sbatch` command
- Supports both human-readable and JSON output formats

## Requirements

- Bash and `scontrol`

## Usage

### Basic usage for CPU/Memory job (uses available resources by default):
```bash
st partition --cpus 4 --mem 8
```

### For GPU jobs (uses available resources by default):
```bash
st partition --cpus 8 --mem 16 --gpus 1
```

### With time limit:
```bash
st partition --cpus 4 --mem 8 --time 96
```

### Show summary of all partitions (shows available resources by default):
```bash
st partition --summary
```

### Use total resources instead of available resources:
```bash
st partition --cpus 4 --mem 8 --gpus 1 --total
```

### Show summary with total resources:
```bash
st partition --summary --total
```

### JSON output (includes available resources by default):
```bash
st partition --cpus 4 --mem 8 --json
```

### JSON output with total resources:
```bash
st partition --cpus 4 --mem 8 --total --json
```

## Command-line Arguments

- `--cpus`: Number of CPUs required (required unless using --summary)
- `--mem`: Memory required in GB (required unless using --summary)
- `--gpus`: Number of GPUs required (default: 0)
- `--time`: Maximum time required in hours (optional)
- `--summary`: Show summary of all partitions (optional)
- `--json`: Output results in JSON format (optional)
- `--total`: Use total resources instead of available resources for filtering and display (optional)
- `--gpu-type`: Filter by GPU type (e.g., a100, h100, v100) (optional)
- `--gpu-memory`: Filter by GPU memory (e.g., 80gb, 40gb) (optional)
- `--exclude`, `-x`: Comma-separated list of partition names to exclude (optional)
- `--name-only`: Print only the best partition name (for scripts)

## GPU Filtering

The script supports advanced GPU filtering to help you find partitions with specific GPU types and memory configurations.

### GPU Type Filtering

Filter partitions by GPU type (e.g., A100, H100, V100):

```bash
# Find partitions with A100 GPUs
st partition --cpus 4 --mem 8 --gpus 1 --gpu-type a100

# Find partitions with H100 GPUs
st partition --cpus 4 --mem 8 --gpus 2 --gpu-type h100
```

### GPU Memory Filtering

Filter partitions by GPU memory size:

```bash
# Find partitions with 80GB GPUs
st partition --cpus 4 --mem 8 --gpus 1 --gpu-memory 80gb

# Find partitions with 40GB GPUs
st partition --cpus 4 --mem 8 --gpus 1 --gpu-memory 40gb
```

### Combined GPU Filtering

Combine both GPU type and memory filtering:

```bash
# Find partitions with A100 80GB GPUs specifically
st partition --cpus 4 --mem 8 --gpus 1 --gpu-type a100 --gpu-memory 80gb
```

### GPU information in summary

Summary mode includes a **GPUInfo** column (lowercased Gres strings aggregated from nodes):

```bash
st partition --summary
```

Use `--gpu-type` / `--gpu-memory` to filter recommendations by substring match against that blob.

### Excluding partitions

Use `--exclude` (or `-x`) to skip specific partitions in a single invocation:

```bash
# Exclude a partition from recommendations
st partition -c 16 -m 64 -g 1 -G h200 --exclude gpu_h200

# Exclude multiple partitions (comma-separated)
st partition -c 16 -m 64 -g 1 --exclude seas_gpu,gpu_h200
```

The same flag works on `st alloc` and `st submit` to exclude partitions from auto-selection:

```bash
st alloc -g 1 -G h200 --exclude gpu_h200
st submit -g 2 --exclude seas_gpu,gpu_h200 train.sh
```

### Partition skip lists (site-specific)

Override defaults with environment variables (space-separated partition names):

- `SLURM_TOOLS_SKIP_PARTITIONS_GPU_JOB` (default: `serial_requeue`)
- `SLURM_TOOLS_SKIP_PARTITIONS_CPU_JOB` (default: `gpu_requeue gpu_test`)

## How It Works

1. **Data Collection**: Runs `scontrol show partition` to get partition information
2. **Resource Fetching** (default): Queries `scontrol show node` to determine currently available resources
3. **GPU Information** (when needed): Queries node-level GPU information to determine GPU types and memory
4. **Parsing**: Extracts `TRESBillingWeights`, resource limits, and other metadata
5. **Filtering**: Removes partitions that cannot meet your requirements:
   - Insufficient CPUs, memory, or GPUs (available by default, or total if `--total` is used)
   - GPU type mismatch (if `--gpu-type` is specified)
   - GPU memory mismatch (if `--gpu-memory` is specified)
   - Time limits shorter than required
   - Partitions not in "UP" state
6. **Cost Calculation**: Calculates billing cost using the formula:
   ```
   Cost = (CPU_count × CPU_weight) + (Memory_GB × Memory_weight) + (GPU_count × GPU_weight)
   ```
7. **Ranking**: Sorts partitions by cost (ascending) and priority tier (lower is better)

## Available vs Total Resources

### Available Resources Mode (Default)
- Uses currently unallocated resources (Total - Allocated)
- Shows what's actually available for immediate use
- Provides more realistic recommendations based on current cluster state
- Filters out partitions that don't have enough available resources right now

### Total Resources Mode (`--total`)
- Uses the total capacity of each partition
- Shows theoretical maximum resources
- May recommend partitions that appear to have capacity but are actually fully utilized
- Useful for planning or understanding partition limits

## Example Output

### Basic Usage (Available Resources - Default)
```bash
$ st partition --cpus 4 --mem 8 --gpus 1

Recommended partitions for your requirements (using available resources):
  CPUs: 4
  Memory: 8.0 GB
  GPUs: 1

Rank Partition            Cost       Max Time        Priority Available Resources
-------------------------------------------------------------------------------------
1    gpu_test             0          12:00:00        4        605 CPUs, 4081 GB, 82 GPUs (a100)
2    serial_requeue       107.6      3-00:00:00      1        21433 CPUs, 341502 GB, 277 GPUs
3    gpu_requeue          107.6      3-00:00:00      2        5862 CPUs, 162313 GB, 277 GPUs

Best recommendation: gpu_test
   Cost: 0 billing units
   Max time: 12:00:00
   Priority tier: 4
   Billing weights: {'CPU': 0.0, 'Mem': 0.0, 'Gres/gpu': 0.0}
   Available resources: 605 CPUs, 4081.8 GB RAM, 82 GPUs (a100)

Suggested sbatch command:
   sbatch --partition=gpu_test --cpus-per-task=4 --mem=8G --gres=gpu:1 your_script.sh
```

### GPU Type Filtering
```bash
$ st partition --cpus 4 --mem 8 --gpus 1 --gpu-type a100

Recommended partitions for your requirements (using available resources):
  CPUs: 4
  Memory: 8.0 GB
  GPUs: 1
  GPU type: a100

Rank Partition            Cost       Max Time        Priority Available Resources
-------------------------------------------------------------------------------------
1    gpu_test             0          12:00:00        4        605 CPUs, 4081 GB, 82 GPUs (a100)
2    gpu                  214.26     3-00:00:00      3        162 CPUs, 15745 GB, 6 GPUs (a100)

Best recommendation: gpu_test
   Cost: 0 billing units
   Max time: 12:00:00
   Priority tier: 4
   Billing weights: {'CPU': 0.0, 'Mem': 0.0, 'Gres/gpu': 0.0}
   Available resources: 605 CPUs, 4081.8 GB RAM, 82 GPUs (a100)
```

### GPU Memory Filtering
```bash
$ st partition --cpus 4 --mem 8 --gpus 1 --gpu-memory 80gb

Recommended partitions for your requirements (using available resources):
  CPUs: 4
  Memory: 8.0 GB
  GPUs: 1
  GPU memory: 80gb

Rank Partition            Cost       Max Time        Priority Available Resources
-------------------------------------------------------------------------------------
1    serial_requeue       107.6      3-00:00:00      1        21433 CPUs, 341502 GB, 277 GPUs
2    gpu_requeue          107.6      3-00:00:00      2        5862 CPUs, 162313 GB, 277 GPUs
3    seas_gpu             337.28     7-00:00:00      3        1299 CPUs, 27983 GB, 22 GPUs
```

### Summary with GPU Information
```bash
$ st partition --summary

Partition            CPU Wt     Mem Wt     GPU Wt     Max Time        State    AvailCPU AvailMemGB AvailGPU GPUInfo
---------------------------------------------------------------------------------------------------------------
gpu_test             0          0          0          12:00:00        UP       605      4081.8     82       a100 ...
gpu_requeue          0.5        0.125      104.6      3-00:00:00      UP       5861     162233.3   276      ...
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
- Use `--total` when you need to see partition limits for planning purposes or when available resources aren't relevant
- **GPU filtering helps find the right hardware** - use `--gpu-type` and `--gpu-memory` to ensure you get the specific GPU hardware needed for your workload
- Some partitions may not have complete GPU information (the GPU column is left blank) - this is normal for partitions with mixed GPU types or where GPU specs cannot be determined
