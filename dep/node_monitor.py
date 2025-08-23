#!/usr/bin/env python3

import subprocess
import re
import argparse
import sys
from dataclasses import dataclass
from typing import List, Dict, Optional
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

@dataclass
class ProcessInfo:
    pid: str
    cpu_percent: float
    memory_mb: float
    command: str

@dataclass 
class NodeUsage:
    node_name: str
    total_cpu_percent: float
    total_memory_mb: float
    process_count: int
    processes: List[ProcessInfo]
    ssh_error: Optional[str] = None

def get_job_nodes(job_id: str) -> List[str]:
    """Get list of nodes for a specific job ID"""
    try:
        result = subprocess.run(['scontrol', 'show', 'job', job_id], 
                              capture_output=True, text=True, check=True)
        
        # Check job state first
        job_state = None
        node_list = None
        
        for line in result.stdout.split('\n'):
            if 'JobState=' in line:
                state_match = re.search(r'JobState=(\S+)', line)
                if state_match:
                    job_state = state_match.group(1)
            
            if 'NodeList=' in line:
                node_match = re.search(r'NodeList=(\S+)', line)
                if node_match:
                    node_list = node_match.group(1)
        
        # Check if job is in a valid state
        if job_state in ['PENDING', 'CONFIGURING']:
            print(f"Job {job_id} is in state {job_state} - no nodes allocated yet")
            return []
        elif job_state in ['COMPLETED', 'FAILED', 'CANCELLED', 'TIMEOUT']:
            print(f"Job {job_id} is {job_state} - no longer running")
            return []
        
        # Check NodeList
        if not node_list or node_list in ['(null)', 'None', '']:
            print(f"Job {job_id} has no valid NodeList (NodeList={node_list})")
            return []
        
        # Handle compressed node names like holygpu8a16[101-103]
        expanded_nodes = expand_node_list(node_list)
        # Filter out None, empty strings, and invalid nodes
        filtered_nodes = [node for node in expanded_nodes if node and node.strip() and node not in ["None", "(null)"]]
        
        if not filtered_nodes:
            print(f"No valid nodes found for job {job_id} (NodeList={node_list})")
            return []
        
        return filtered_nodes
                
    except subprocess.CalledProcessError as e:
        print(f"Error getting job {job_id}: {e}")
        return []

def expand_node_list(node_list: str) -> List[str]:
    """Expand SLURM compressed node names like holygpu8a16[101-103] to individual nodes"""
    if not node_list or node_list.strip() == "" or node_list in ["None", "(null)"]:
        return []
        
    node_list = node_list.strip()
    nodes = []
    
    # Handle simple case (single node)
    if '[' not in node_list:
        return [node_list]
    
    # Handle compressed format
    match = re.match(r'(.+)\[(.+)\]', node_list)
    if match:
        prefix = match.group(1)
        range_part = match.group(2)
        
        # Handle ranges like 101-103 or simple lists like 101,102,103
        if '-' in range_part:
            parts = range_part.split(',')
            for part in parts:
                part = part.strip()
                if '-' in part:
                    start, end = part.split('-')
                    start_num = int(start.strip())
                    end_num = int(end.strip())
                    for i in range(start_num, end_num + 1):
                        # Preserve original formatting (e.g., 001 vs 1)
                        if len(start.strip()) > 1 and start.strip().startswith('0'):
                            nodes.append(f"{prefix}{i:0{len(start.strip())}d}")
                        else:
                            nodes.append(f"{prefix}{i}")
                else:
                    nodes.append(f"{prefix}{part}")
        else:
            # Simple comma-separated list
            for num in range_part.split(','):
                num = num.strip()
                if num:
                    nodes.append(f"{prefix}{num}")
    
    # Filter out any empty or invalid values
    return [node for node in nodes if node and node.strip() and node not in ["None", "(null)"]]

def get_node_processes(node: str, username: str, process_filter: Optional[str] = None) -> NodeUsage:
    """SSH to node and get process information for the user"""
    try:
        # Use ps to get process info with CPU and memory usage
        # Format: PID %CPU %MEM COMMAND
        cmd = [
            'ssh', node,
            f"ps -u {username} -o pid,%cpu,%mem,comm --no-headers"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, 
                              timeout=30, check=True)
        print(result.stdout)
        
        processes = []
        total_cpu = 0.0
        total_memory = 0.0
        
        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
                
            parts = line.strip().split(None, 3)
            if len(parts) >= 4:
                pid = parts[0]
                cpu_percent = float(parts[1])
                mem_percent = float(parts[2])
                command = parts[3]
                
                # Convert memory percentage to MB (rough estimation)
                # We'll get total memory from /proc/meminfo
                memory_mb = mem_percent  # Will convert later
                
                # Apply process filter if specified
                if process_filter is None or process_filter.lower() in command.lower():
                    processes.append(ProcessInfo(pid, cpu_percent, memory_mb, command))
                    total_cpu += cpu_percent
                    total_memory += mem_percent
        
        # Get total system memory to convert percentages to MB
        cmd_mem = ['ssh', node, 'cat /proc/meminfo | grep MemTotal']
        mem_result = subprocess.run(cmd_mem, capture_output=True, text=True, timeout=10)
        
        total_system_memory_kb = 0
        if mem_result.returncode == 0:
            mem_match = re.search(r'MemTotal:\s+(\d+)\s+kB', mem_result.stdout)
            if mem_match:
                total_system_memory_kb = int(mem_match.group(1))
                total_system_memory_mb = total_system_memory_kb / 1024
                
                # Convert memory percentages to MB
                for process in processes:
                    process.memory_mb = (process.memory_mb / 100.0) * total_system_memory_mb
                
                total_memory = (total_memory / 100.0) * total_system_memory_mb
        
        return NodeUsage(node, total_cpu, total_memory, len(processes), processes)
        
    except subprocess.TimeoutExpired:
        return NodeUsage(node, 0, 0, 0, [], "SSH timeout")
    except subprocess.CalledProcessError as e:
        return NodeUsage(node, 0, 0, 0, [], f"SSH error: {e}")
    except Exception as e:
        return NodeUsage(node, 0, 0, 0, [], f"Error: {e}")

def print_usage_table(node_usages: List[NodeUsage], process_filter: Optional[str] = None):
    """Print formatted table of node usage"""
    if not node_usages:
        print("No data to display")
        return
    
    # Print header with filter info if applicable
    print(f"{'Node':<20} {'CPU%':<8} {'Memory(MB)':<12} {'Processes':<10} {'Status'}")
    print(f"{'----':<20} {'----':<8} {'---------':<12} {'---------':<10} {'------'}")
    if process_filter:
        print(f"Process filter: '{process_filter}' (case-insensitive substring match)")
        print()
    
    total_processes = 0
    total_cpu = 0.0
    total_memory = 0.0
    
    for usage in node_usages:
        status = "OK" if usage.ssh_error is None else "ERROR"
        
        print(f"{usage.node_name:<20} {usage.total_cpu_percent:<8.1f} "
              f"{usage.total_memory_mb:<12.1f} {usage.process_count:<10} {status}")
        
        if usage.ssh_error:
            print(f"    Error: {usage.ssh_error}")
        
        if usage.ssh_error is None:
            total_processes += usage.process_count
            total_cpu += usage.total_cpu_percent
            total_memory += usage.total_memory_mb
    
    print(f"\nSummary:")
    print(f"Total processes: {total_processes}")
    print(f"Total CPU%: {total_cpu:.1f}")
    print(f"Total Memory: {total_memory:.1f} MB")

def main():
    parser = argparse.ArgumentParser(description='Monitor CPU/memory usage of processes for a specific SLURM job')
    parser.add_argument('--job-id', '-j', required=True,
                       help='SLURM job ID to monitor')
    parser.add_argument('--json', action='store_true',
                       help='Output in JSON format')
    parser.add_argument('--proc', '-f', default=None,
                       help='filter processes by name (substring match, case-insensitive)')
    
    args = parser.parse_args()
    
    # Get username for process filtering
    try:
        username = subprocess.run(['whoami'], capture_output=True, text=True, check=True).stdout.strip()
    except:
        print("Error: Could not determine username")
        sys.exit(1)
    
    print(f"Monitoring job {args.job_id} for user: {username}")
    
    # Get nodes for the specific job
    print(f"Getting nodes for job {args.job_id}...")
    nodes = get_job_nodes(args.job_id)
    if not nodes:
        print(f"No valid nodes found for job {args.job_id}")
        print(f"Try checking job status with: scontrol show job {args.job_id}")
        sys.exit(1)
    print(f"Found {len(nodes)} nodes: {', '.join(nodes)}")
    
    # Check each node in parallel
    print(f"\nChecking {len(nodes)} nodes in parallel...")
    node_usages = []
    
    # Thread-safe printing
    print_lock = threading.Lock()
    
    def check_node_with_progress(node):
        usage = get_node_processes(node, username, args.proc)
        with print_lock:
            if usage.ssh_error:
                print(f"✗ {node}: ERROR - {usage.ssh_error}")
            else:
                filter_msg = f" (filtered by '{args.proc}')" if args.proc else ""
                print(f"✓ {node}: OK ({usage.process_count} processes{filter_msg})")
        return usage
    
    # Use ThreadPoolExecutor for parallel execution
    with ThreadPoolExecutor(max_workers=min(len(nodes), 10)) as executor:
        # Submit all tasks
        future_to_node = {executor.submit(check_node_with_progress, node): node for node in nodes}
        
        # Collect results as they complete
        for future in as_completed(future_to_node):
            usage = future.result()
            node_usages.append(usage)
    
    # Sort results by node name for consistent output
    node_usages.sort(key=lambda x: x.node_name)
    print()
    
    # Output results
    if args.json:
        # JSON output
        data = []
        for usage in node_usages:
            node_data = {
                'node': usage.node_name,
                'cpu_percent': usage.total_cpu_percent,
                'memory_mb': usage.total_memory_mb,
                'process_count': usage.process_count,
                'error': usage.ssh_error
            }
            node_data['processes'] = [
                {
                    'pid': p.pid,
                    'cpu_percent': p.cpu_percent,
                    'memory_mb': p.memory_mb,
                    'command': p.command
                } for p in usage.processes
            ]
            data.append(node_data)
        
        print(json.dumps(data, indent=2))
    else:
        # Table output
        print_usage_table(node_usages, args.proc)

if __name__ == '__main__':
    main() 