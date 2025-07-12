# SLURM Node Allocation Monitor

`print_alloc.py` is a Python script that provides a clean, sortable view of SLURM node resource allocation across GPU partitions. It displays unallocated resources (GPUs, CPUs, memory) to help users quickly identify available nodes for job submission.

## Features

- **Resource Monitoring**: Shows unallocated GPUs, CPUs, and memory for each node
- **Smart Sorting**: Automatically sorts nodes by available resources (most available first)
- **State Filtering**: Automatically filters out DOWN nodes
- **Flexible Display**: Two viewing modes (default and detailed)
- **Clean Output**: Formatted table with proper column alignment
- **Multi-partition Support**: Query any SLURM partition

## Installation

1. Ensure you have Python 3.6+ installed
2. Make the script executable:
   ```bash
   chmod +x print_alloc.py
   ```

## Usage

### Basic Usage

```bash
# Show unallocated resources for seas_gpu partition (default)
./print_alloc.py

# Show unallocated resources for a specific partition
./print_alloc.py --partition gpu_partition
./print_alloc.py -p gpu_partition
```

### Detailed View

```bash
# Show additional utilization information
./print_alloc.py --available
./print_alloc.py -a
```

## Command Line Options

| Option | Short | Description |
|--------|-------|-------------|
| `--available` | `-a` | Show detailed view with CPU load and used memory |
| `--partition` | `-p` | Specify partition to query (default: seas_gpu) |
| `--help` | `-h` | Show help message |

## Output Columns

### Default View
- **NodeName**: Node identifier
- **UnallocGPU**: Number of unallocated GPUs
- **UnallocCPU**: Number of unallocated CPUs  
- **UnallocMem(GB)**: Unallocated memory in GB
- **Gres**: GPU type and configuration
- **State**: Current node state
- **AllocTRES**: Currently allocated trackable resources

### Detailed View (`--available`)
- **NodeName**: Node identifier
- **UnallocGPU**: Number of unallocated GPUs
- **UnallocCPU**: Number of unallocated CPUs
- **UnallocMem(GB)**: Unallocated memory in GB
- **CPULoad**: Current CPU utilization
- **UsedMem(GB)**: Currently used memory in GB
- **Gres**: GPU type and configuration
- **State**: Current node state
- **AllocTRES**: Currently allocated trackable resources

## Sorting Logic

Nodes are automatically sorted by:
1. **Unallocated GPUs** (descending - most available first)
2. **Unallocated CPUs** (descending - most available first)  
3. **Unallocated Memory** (descending - most available first)

This ensures nodes with the most available resources appear at the top.

## Examples

### Example 1: Basic Usage
```bash
$ ./print_alloc.py

NodeName             UnallocGPU UnallocCPU UnallocMem(GB) Gres                     State           AllocTRES
--------             ---------- ---------- -------------- ----                     -----           --------
holygpu8a16101       4          55         234.5          nvidia_a100-sxm4-80gb:4 IDLE            cpu=9,mem=65G
holygpu8a16102       3          48         198.2          nvidia_a100-sxm4-80gb:4 MIXED           cpu=16,mem=101G,gres/gpu=1
holygpu8a16103       2          32         156.7          nvidia_a100-sxm4-80gb:4 MIXED           cpu=32,mem=143G,gres/gpu=2
```

### Example 2: Detailed View
```bash
$ ./print_alloc.py --available

NodeName             UnallocGPU UnallocCPU UnallocMem(GB) CPULoad  UsedMem(GB) Gres                     State           AllocTRES
--------             ---------- ---------- -------------- -------- ----------- ----                     -----           --------
holygpu8a16101       4          55         234.5          2.1      45.2        nvidia_a100-sxm4-80gb:4 IDLE            cpu=9,mem=65G
holygpu8a16102       3          48         198.2          16.8     89.3        nvidia_a100-sxm4-80gb:4 MIXED           cpu=16,mem=101G,gres/gpu=1
```

### Example 3: Different Partition
```bash
$ ./print_alloc.py --partition gpu_test

NodeName             UnallocGPU UnallocCPU UnallocMem(GB) Gres                     State           AllocTRES
--------             ---------- ---------- -------------- ----                     -----           --------
testgpu01            8          128        512.0          nvidia_h100_80gb_hbm3:8 IDLE            
testgpu02            6          96         384.0          nvidia_h100_80gb_hbm3:8 MIXED           cpu=32,mem=128G,gres/gpu=2
```

## Understanding the Output

### GPU Information
- **UnallocGPU**: GPUs available for new jobs
- **Gres**: Shows GPU type (e.g., `nvidia_a100-sxm4-80gb:4` = 4 A100 GPUs)
- Socket information like `(S:0-1)` is automatically cleaned from display

### Memory Information
- **UnallocMem(GB)**: Memory not allocated to SLURM jobs (available for scheduling)
- **UsedMem(GB)**: Memory currently used by the OS and processes (detailed view only)
- All memory values are displayed in GB for readability

### CPU Information
- **UnallocCPU**: CPU cores not allocated to SLURM jobs
- **CPULoad**: Current CPU utilization (detailed view only)

### Node States
Common SLURM node states:
- **IDLE**: Node is available and not running any jobs
- **MIXED**: Node is partially allocated (some resources in use)
- **ALLOCATED**: Node is fully allocated to jobs
- **DRAIN**: Node is being drained (no new jobs accepted)
- **DOWN**: Node is offline (automatically filtered out)

## Troubleshooting

### Common Issues

1. **Permission Denied**
   ```bash
   chmod +x print_alloc.py
   ```

2. **Partition Not Found**
   ```bash
   # Check available partitions
   sinfo -s
   
   # Use correct partition name
   ./print_alloc.py --partition correct_partition_name
   ```

3. **No Output**
   - Check if partition has nodes: `scontrol show partition partition_name`
   - Verify SLURM is accessible: `squeue`

### Dependencies

- Python 3.6+
- SLURM client tools (`scontrol`, `sinfo`)
- Standard Python libraries: `subprocess`, `re`, `argparse`, `dataclasses`

## Technical Details

### Resource Calculation
- **Unallocated GPUs**: `Total GPUs - Allocated GPUs`
- **Unallocated CPUs**: `Total CPUs - Allocated CPUs`
- **Unallocated Memory**: `Total Memory - Allocated Memory`

### Data Sources
- Node information from `scontrol show node`
- Partition information from `scontrol show partition`
- Resource allocation from SLURM's AllocTRES field

## Contributing

To extend or modify the script:

1. **Adding new columns**: Extend the `NodeInfo` dataclass and parsing logic
2. **Custom sorting**: Modify the sorting key in `print_nodes()`
3. **Additional filters**: Add filters in the `print_nodes()` function
4. **New output formats**: Create additional display functions

## License

This script is provided as-is for use with SLURM cluster management. 