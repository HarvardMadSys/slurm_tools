# Node Monitor - SLURM Job Process Monitoring Script

Monitor CPU and memory usage of processes for a specific SLURM job. The script gets the node list from the job ID and SSH to each node to collect process information for your user.

## Features

- **Job-specific monitoring**: Monitor processes for a specific SLURM job ID
- **Parallel Processing**: SSH to multiple nodes simultaneously for fast execution
- **SSH Monitoring**: SSH to each node to get real-time process information  
- **Resource Usage**: Shows CPU percentage and memory usage (in MB)
- **Process Filtering**: Filter processes by name (case-insensitive substring matching)
- **Error Handling**: Graceful handling of SSH timeouts and connection errors
- **Null Filtering**: Automatically filters out invalid/null node entries
- **Multiple Output Formats**: Table or JSON output (JSON includes process details)
- **Simple Interface**: Clean command-line interface focused on job monitoring

## Usage

### Basic Usage (Specify job ID)
```bash
# Monitor processes for a specific job
./node_monitor.py --job-id 12345678

# Filter processes (only show Python processes)
./node_monitor.py --job-id 12345678 --proc python

# Filter GPU-related processes
./node_monitor.py --job-id 12345678 --proc nvidia
```

### JSON Output
```bash
# Get JSON output for programmatic use (includes process details)
./node_monitor.py --job-id 12345678 --json

# JSON with filtering
./node_monitor.py --job-id 12345678 --json --proc python
```

## Command Line Options

| Option | Short | Description |
|--------|-------|-------------|
| `--job-id` | `-j` | SLURM job ID to monitor (required) |
| `--proc` | `-f` | Filter processes by name (case-insensitive substring match) |
| `--json` | | Output results in JSON format (includes process details) |
| `--help` | `-h` | Show help message |

## Output Format

### Table Format (Default)
```
Node                 CPU%     Memory(MB)   Processes  Status
----                 ----     ---------    ---------  ------
holygpu8a16101       45.2     8432.1       12         OK
holygpu8a16102       23.8     4521.3       8          OK
holygpu8a16103       0.0      0.0          0          ERROR

Summary:
Total processes: 20
Total CPU%: 69.0
Total Memory: 12953.4 MB
```

### With Process Filtering (`--proc python`)
```
Node                 CPU%     Memory(MB)   Processes  Status
----                 ----     ---------    ---------  ------
Process filter: 'python' (case-insensitive substring match)

holygpu8a16101       38.5     7234.2       3          OK
holygpu8a16102       15.2     2145.1       2          OK
holygpu8a16103       0.0      0.0          0          OK

Summary:
Total processes: 5
Total CPU%: 53.7
Total Memory: 9379.3 MB
```



### JSON Format (`--json`)
```json
[
  {
    "node": "holygpu8a16101",
    "cpu_percent": 45.2,
    "memory_mb": 8432.1,
    "process_count": 12,
    "error": null,
    "processes": [
      {
        "pid": "1234567",
        "cpu_percent": 25.3,
        "memory_mb": 4521.0,
        "command": "python"
      },
      {
        "pid": "1234568",
        "cpu_percent": 15.2,
        "memory_mb": 2341.0,
        "command": "nvidia-smi"
      }
    ]
  }
]
```

## How It Works

1. **Job Node Discovery**: Uses `scontrol show job <job_id>` to get NodeList for the specific job
2. **Node Expansion**: Expands SLURM compressed node names (e.g., `node[01-03]`)
3. **Null Filtering**: Removes invalid, empty, or null node entries from the list
4. **Parallel SSH Monitoring**: Uses ThreadPoolExecutor to SSH to up to 10 nodes simultaneously
5. **Process Collection**: Runs `ps -u username` on each node to get process info
6. **Process Filtering**: Applies name-based filtering (case-insensitive substring match)
7. **Memory Calculation**: Converts memory percentages to MB using `/proc/meminfo`
8. **Result Aggregation**: Sorts and summarizes CPU/memory usage per node and overall

## Examples

### Monitor a Specific Job
```bash
$ ./node_monitor.py --job-id 12345678
Monitoring job 12345678 for user: juncheng
Getting nodes for job 12345678...
Found 2 nodes: holygpu8a16101, holygpu8a16102

Checking 2 nodes in parallel...
✓ holygpu8a16101: OK (8 processes)
✓ holygpu8a16102: OK (4 processes)

Node                 CPU%     Memory(MB)   Processes  Status
----                 ----     ---------    ---------  ------
holygpu8a16101       156.8    12453.2      8          OK
holygpu8a16102       89.3     6234.1       4          OK

Summary:
Total processes: 12
Total CPU%: 246.1
Total Memory: 18687.3 MB
```

### Filter Specific Processes
```bash
$ ./node_monitor.py --job-id 12345678 --proc python
Monitoring job 12345678 for user: juncheng
Getting nodes for job 12345678...
Found 2 nodes: holygpu8a16101, holygpu8a16102

Checking 2 nodes in parallel...
✓ holygpu8a16101: OK (3 processes (filtered by 'python'))
✓ holygpu8a16102: OK (2 processes (filtered by 'python'))

Node                 CPU%     Memory(MB)   Processes  Status
----                 ----     ---------    ---------  ------
Process filter: 'python' (case-insensitive substring match)

holygpu8a16101       98.5     8234.1       3          OK
holygpu8a16102       67.3     5123.4       2          OK

Summary:
Total processes: 5
Total CPU%: 165.8
Total Memory: 13357.5 MB
```



## Troubleshooting

### Common Issues

1. **Job not found**
   - Make sure the job ID exists: `scontrol show job <job_id>`
   - Check if the job is still running: `squeue -j <job_id>`

2. **SSH errors/timeouts**
   - Check if you can SSH to the node manually: `ssh nodename`
   - Some nodes may be unreachable or have SSH restrictions
   - The script has a 30-second timeout per node

3. **Permission denied**
   - Make sure the script is executable: `chmod +x node_monitor.py`
   - Ensure you have SSH access to compute nodes

4. **No processes found**
   - Check if processes are running under your username: `ssh nodename ps -u $(whoami)`
   - Some processes may have finished between job discovery and monitoring

5. **Filter not finding processes**
   - Check if the filter string matches your process names: `ssh nodename ps -u $(whoami) | grep -i filtername`
   - The filter is case-insensitive substring matching, so "python" matches "python", "Python", "python3", etc.

### Dependencies

- Python 3.6+ with standard libraries (including `concurrent.futures` and `threading`)
- SLURM client tools (`squeue`, `scontrol`)
- SSH access to compute nodes
- Standard Unix tools on compute nodes (`ps`, `cat`)

### Performance

- **Parallel Processing**: Up to 10 nodes checked simultaneously (configurable)
- **Speed**: ~3-5x faster than sequential checking for multiple nodes
- **Efficiency**: Thread-safe output and proper resource cleanup

## Common Process Filtering Examples

```bash
# Monitor only Python processes for a job
./node_monitor.py --job-id 12345678 --proc python

# Monitor GPU-related processes
./node_monitor.py --job-id 12345678 --proc nvidia

# Monitor machine learning frameworks
./node_monitor.py --job-id 12345678 --proc torch      # PyTorch processes
./node_monitor.py --job-id 12345678 --proc tensorflow # TensorFlow processes

# Monitor specific applications
./node_monitor.py --job-id 12345678 --proc jupyter    # Jupyter processes
./node_monitor.py --job-id 12345678 --proc code       # VS Code processes
./node_monitor.py --job-id 12345678 --proc ssh        # SSH processes

# Case-insensitive matching examples:
./node_monitor.py --job-id 12345678 --proc PYTHON     # matches "python", "Python", "python3"
./node_monitor.py --job-id 12345678 --proc cuda       # matches "cuda", "CUDA", "cudamallocasync"
./node_monitor.py --job-id 12345678 --proc mpi        # matches "mpi", "MPI", "mpirun", "mpiexec"

# Combine with JSON output
./node_monitor.py --job-id 12345678 --proc python --json  # Detailed Python processes in JSON
```

## Integration with Existing Tools

This script complements the existing SLURM tools in your toolkit:

- **`print_alloc`**: Shows available resources across nodes
- **`best_partition`**: Finds optimal partition for job submission
- **`node_monitor`**: Monitors actual resource usage of running jobs

```bash
best_partition --cpu 16 --mem 256 --gpu 1
sbatch -p recommended_partition job.sbatch
node_monitor --job-id <job_id>
``` 