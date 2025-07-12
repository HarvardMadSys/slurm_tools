#!/usr/bin/env python3
"""
SLURM Partition Optimizer

This script analyzes SLURM partition TRESBillingWeights and recommends the best
partition to use based on your resource requirements.

Usage:
    python partition_optimizer.py --cpu 4 --mem 8 --gpu 1
"""

import subprocess
import re
import argparse
import json


class PartitionInfo:
    """Information about a SLURM partition."""
    
    def __init__(self, name, max_time, total_cpus, total_nodes, total_memory_mb, 
                 total_gpus, billing_weights, state, priority_tier):
        self.name = name
        self.max_time = max_time
        self.total_cpus = total_cpus
        self.total_nodes = total_nodes
        self.total_memory_mb = total_memory_mb
        self.total_gpus = total_gpus
        self.billing_weights = billing_weights
        self.state = state
        self.priority_tier = priority_tier
    
    def calculate_cost(self, cpu_req, memory_gb_req, gpu_req):
        """Calculate the billing cost for given requirements."""
        cost = 0.0
        
        # CPU cost
        if 'CPU' in self.billing_weights:
            cost += cpu_req * self.billing_weights['CPU']
        
        # Memory cost (weights are typically per GB)
        if 'Mem' in self.billing_weights:
            cost += memory_gb_req * self.billing_weights['Mem']
        
        # GPU cost
        if 'Gres/gpu' in self.billing_weights:
            cost += gpu_req * self.billing_weights['Gres/gpu']
        
        return cost


def run_scontrol():
    """Run scontrol show partition command and return output."""
    try:
        result = subprocess.run(['scontrol', 'show', 'partition'], 
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, 
                              universal_newlines=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        print("Error running scontrol: {}".format(e))
        return ""
    except FileNotFoundError:
        print("scontrol command not found. Make sure SLURM is installed.")
        return ""


def parse_billing_weights(weights_str):
    """Parse TRESBillingWeights string into a dictionary."""
    weights = {}
    if not weights_str:
        return weights
    
    # Split by comma and parse each weight
    for weight_pair in weights_str.split(','):
        if '=' in weight_pair:
            key, value = weight_pair.split('=', 1)
            key = key.strip()
            value = value.strip()
            
            # Handle memory weights that might have 'G' suffix
            if value.endswith('G'):
                value = value[:-1]
            
            try:
                weights[key] = float(value)
            except ValueError:
                print("Warning: Could not parse weight value '{}' for '{}'".format(value, key))
                weights[key] = 0.0
    
    return weights


def parse_time_limit(time_str):
    """Convert time limit string to minutes for comparison."""
    if time_str == "UNLIMITED":
        return float('inf')
    
    # Parse formats like "3-00:00:00" (days-hours:minutes:seconds)
    if '-' in time_str:
        days, time_part = time_str.split('-', 1)
        days = int(days)
    else:
        days = 0
        time_part = time_str
    
    # Parse hours:minutes:seconds
    time_parts = time_part.split(':')
    if len(time_parts) == 3:
        hours, minutes, seconds = map(int, time_parts)
    elif len(time_parts) == 2:
        hours, minutes = map(int, time_parts)
        seconds = 0
    else:
        return 0
    
    total_minutes = days * 24 * 60 + hours * 60 + minutes
    return total_minutes


def extract_memory_from_tres(tres_str):
    """Extract memory in MB from TRES string."""
    # Look for patterns like "mem=37122372M"
    match = re.search(r'mem=(\d+)M', tres_str)
    if match:
        return int(match.group(1))
    return 0


def extract_gpu_from_tres(tres_str):
    """Extract total GPU count from TRES string."""
    # Look for patterns like "gres/gpu=144"
    match = re.search(r'gres/gpu=(\d+)', tres_str)
    if match:
        return int(match.group(1))
    return 0


def parse_partition_output(output):
    """Parse scontrol show partition output into PartitionInfo objects."""
    partitions = []
    
    # Split output into individual partition blocks
    partition_blocks = re.split(r'\n(?=PartitionName=)', output)
    
    for block in partition_blocks:
        if not block.strip():
            continue
            
        # Extract partition name
        name_match = re.search(r'PartitionName=(\w+)', block)
        if not name_match:
            continue
        name = name_match.group(1)
        
        # Extract max time
        max_time_match = re.search(r'MaxTime=([^\s]+)', block)
        max_time = max_time_match.group(1) if max_time_match else "UNLIMITED"
        
        # Extract total CPUs
        cpu_match = re.search(r'TotalCPUs=(\d+)', block)
        total_cpus = int(cpu_match.group(1)) if cpu_match else 0
        
        # Extract total nodes
        node_match = re.search(r'TotalNodes=(\d+)', block)
        total_nodes = int(node_match.group(1)) if node_match else 0
        
        # Extract TRES information
        tres_match = re.search(r'TRES=([^\n]+)', block)
        tres_str = tres_match.group(1) if tres_match else ""
        
        # Extract memory and GPU from TRES
        total_memory_mb = extract_memory_from_tres(tres_str)
        total_gpus = extract_gpu_from_tres(tres_str)
        
        # Extract billing weights
        weights_match = re.search(r'TRESBillingWeights=([^\n]+)', block)
        weights_str = weights_match.group(1) if weights_match else ""
        billing_weights = parse_billing_weights(weights_str)
        
        # Extract state
        state_match = re.search(r'State=([^\s]+)', block)
        state = state_match.group(1) if state_match else "UNKNOWN"
        
        # Extract priority tier
        priority_match = re.search(r'PriorityTier=(\d+)', block)
        priority_tier = int(priority_match.group(1)) if priority_match else 0
        
        partition = PartitionInfo(
            name=name,
            max_time=max_time,
            total_cpus=total_cpus,
            total_nodes=total_nodes,
            total_memory_mb=total_memory_mb,
            total_gpus=total_gpus,
            billing_weights=billing_weights,
            state=state,
            priority_tier=priority_tier
        )
        
        partitions.append(partition)
    
    return partitions


def filter_suitable_partitions(partitions, cpu_req, memory_gb_req, gpu_req, max_time_hours=None):
    """Filter partitions that can accommodate the requirements."""
    suitable = []
    
    for partition in partitions:
        # Skip if partition is not up
        if partition.state != "UP":
            continue
            
        # Check if partition has enough resources
        if cpu_req > partition.total_cpus and partition.total_cpus > 0:
            continue
        
        if memory_gb_req * 1024 > partition.total_memory_mb and partition.total_memory_mb > 0:
            continue
        
        # For GPU requirements, skip partitions with no GPUs if GPUs are requested
        if gpu_req > 0 and partition.total_gpus == 0:
            continue
        
        # For partitions with GPUs, check if they have enough
        if gpu_req > partition.total_gpus and partition.total_gpus > 0:
            continue
        
        # Check time limit if specified
        if max_time_hours is not None:
            partition_time_minutes = parse_time_limit(partition.max_time)
            if partition_time_minutes != float('inf') and partition_time_minutes < max_time_hours * 60:
                continue
        
        suitable.append(partition)
    
    return suitable


def find_best_partitions(partitions, cpu_req, memory_gb_req, gpu_req, max_time_hours=None):
    """Find the best partitions ranked by cost."""
    suitable_partitions = filter_suitable_partitions(
        partitions, cpu_req, memory_gb_req, gpu_req, max_time_hours
    )
    
    if not suitable_partitions:
        return []
    
    # Calculate costs and sort by cost
    partition_costs = []
    for partition in suitable_partitions:
        cost = partition.calculate_cost(cpu_req, memory_gb_req, gpu_req)
        partition_costs.append((partition, cost))
    
    # Sort by cost (ascending), then by priority tier (lower is better)
    partition_costs.sort(key=lambda x: (x[1], x[0].priority_tier))
    
    return partition_costs


def print_partition_summary(partitions):
    """Print a summary of all partitions."""
    print("{:<20} {:<10} {:<10} {:<10} {:<15} {:<8}".format(
        'Partition', 'CPU Weight', 'Mem Weight', 'GPU Weight', 'Max Time', 'State'))
    print("-" * 90)
    
    for partition in partitions:
        cpu_weight = partition.billing_weights.get('CPU', 0.0)
        mem_weight = partition.billing_weights.get('Mem', 0.0)
        gpu_weight = partition.billing_weights.get('Gres/gpu', 0.0)
        
        print("{:<20} {:<10.3f} {:<10.3f} {:<10.3f} {:<15} {:<8}".format(
            partition.name, cpu_weight, mem_weight, gpu_weight, partition.max_time, partition.state))


def main():
    parser = argparse.ArgumentParser(description='Find the best SLURM partition for your job requirements')
    parser.add_argument('--cpu', "-c", type=int, help='Number of CPUs required')
    parser.add_argument('--mem', "-m", type=float, help='Memory required in GB')
    parser.add_argument('--gpu', "-g", type=int, default=0, help='Number of GPUs required (default: 0)')
    parser.add_argument('--time', "-t", type=int, help='Maximum time required in hours')
    parser.add_argument('--summary', "-s", action='store_true', help='Show summary of all partitions')
    parser.add_argument('--json', "-j", action='store_true', help='Output results in JSON format')
    
    args = parser.parse_args()
    
    # Get partition information
    print("Fetching partition information...")
    output = run_scontrol()
    if not output:
        print("Failed to get partition information.")
        return
    
    partitions = parse_partition_output(output)
    
    if args.summary:
        print_partition_summary(partitions)
        return
    
    # Check required arguments for non-summary mode
    if args.cpu is None or args.mem is None:
        print("Error: --cpu and --mem are required unless using --summary")
        return
    
    # Find best partitions
    best_partitions = find_best_partitions(
        partitions, args.cpu, args.mem, args.gpu, args.time
    )
    
    if not best_partitions:
        print("No suitable partitions found for your requirements.")
        return
    
    if args.json:
        # Output in JSON format
        results = []
        for partition, cost in best_partitions:
            results.append({
                'name': partition.name,
                'cost': cost,
                'max_time': partition.max_time,
                'priority_tier': partition.priority_tier,
                'billing_weights': partition.billing_weights,
                'total_cpus': partition.total_cpus,
                'total_memory_gb': partition.total_memory_mb // 1024,
                'total_gpus': partition.total_gpus
            })
        print(json.dumps(results, indent=2))
    else:
        # Human-readable output
        print("\nRecommended partitions for your requirements:")
        print("  CPUs: {}".format(args.cpu))
        print("  Memory: {} GB".format(args.mem))
        print("  GPUs: {}".format(args.gpu))
        if args.time:
            print("  Max time: {} hours".format(args.time))
        print()
        
        print("{:<4} {:<20} {:<10} {:<15} {:<8} {}".format(
            'Rank', 'Partition', 'Cost', 'Max Time', 'Priority', 'Details'))
        print("-" * 85)
        
        for i, (partition, cost) in enumerate(best_partitions[:10], 1):
            details = []
            if partition.total_cpus > 0:
                details.append("{} CPUs".format(partition.total_cpus))
            if partition.total_memory_mb > 0:
                details.append("{} GB".format(partition.total_memory_mb//1024))
            if partition.total_gpus > 0:
                details.append("{} GPUs".format(partition.total_gpus))
            
            details_str = ", ".join(details)
            
            print("{:<4} {:<20} {:<10.3f} {:<15} {:<8} {}".format(
                i, partition.name, cost, partition.max_time, partition.priority_tier, details_str))
        
        # Show the top recommendation
        if best_partitions:
            best_partition, best_cost = best_partitions[0]
            print("\n🎯 Best recommendation: {}".format(best_partition.name))
            print("   Cost: {:.3f} billing units".format(best_cost))
            print("   Max time: {}".format(best_partition.max_time))
            print("   Priority tier: {}".format(best_partition.priority_tier))
            print("   Billing weights: {}".format(best_partition.billing_weights))
            
            # Show sbatch command suggestion
            print("\n📋 Suggested sbatch command:")
            cmd = "   sbatch --partition={} --cpus-per-task={} --mem={}G".format(
                best_partition.name, args.cpu, int(args.mem))
            if args.gpu > 0:
                cmd += " --gres=gpu:{}".format(args.gpu)
            if args.time:
                cmd += " --time={}:00:00".format(args.time)
            cmd += " your_script.sh"
            print(cmd)


if __name__ == "__main__":
    main()