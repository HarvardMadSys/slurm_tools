#!/usr/bin/env python3

import subprocess
import re
import argparse
from dataclasses import dataclass
from typing import List, Optional

@dataclass
class NodeInfo:
    name: str
    cpu_efctv: int
    cpu_load: float
    gres: str
    real_memory: int
    free_mem: int
    state: str
    alloc_tres: str
    
    @property
    def total_gpus(self) -> int:
        """Extract total GPU count from gres string"""
        # Look for pattern like "nvidia_h100_80gb_hbm3:4" or "nvidia_a100-sxm4-80gb:4"
        # The number after the colon is the total GPU count
        match = re.search(r'nvidia_[^:]+:(\d+)', self.gres)
        return int(match.group(1)) if match else 0
    
    @property
    def allocated_gpus(self) -> int:
        """Extract allocated GPU count from AllocTRES"""
        match = re.search(r'gres/gpu=(\d+)', self.alloc_tres)
        return int(match.group(1)) if match else 0
    
    @property
    def allocated_cpus(self) -> int:
        """Extract allocated CPU count from AllocTRES"""
        match = re.search(r'cpu=(\d+)', self.alloc_tres)
        return int(match.group(1)) if match else 0
    
    @property
    def unallocated_gpus(self) -> int:
        return self.total_gpus - self.allocated_gpus
    
    @property
    def unallocated_cpus(self) -> int:
        return self.cpu_efctv - self.allocated_cpus
    
    @property
    def allocated_memory(self) -> int:
        """Extract allocated memory from AllocTRES (in MB)"""
        # Look for patterns like "mem=482G" or "mem=329024M"
        match = re.search(r'mem=(\d+)([GM]?)', self.alloc_tres)
        if match:
            value = int(match.group(1))
            unit = match.group(2)
            if unit == 'G':
                return value * 1024  # Convert GB to MB
            else:
                return value  # Already in MB
        return 0
    
    @property
    def unallocated_memory(self) -> int:
        """Calculate unallocated memory in MB"""
        return self.real_memory - self.allocated_memory
    
    @property
    def unallocated_memory_gb(self) -> float:
        """Calculate unallocated memory in GB"""
        return self.unallocated_memory / 1024.0
    
    @property
    def used_memory_gb(self) -> float:
        """Calculate used memory in GB (RealMemory - FreeMem)"""
        used_mb = self.real_memory - self.free_mem
        return used_mb / 1024.0  # Convert MB to GB
    
    @property
    def clean_gres(self) -> str:
        """Clean up gres string by removing gpu: prefix and socket info"""
        cleaned = self.gres
        cleaned = re.sub(r'^gpu:', '', cleaned)  # Remove gpu: prefix
        cleaned = re.sub(r'\([^)]*\)', '', cleaned)  # Remove socket info like (S:0-1)
        return cleaned

def get_partition_nodes(partition_name: str) -> str:
    """Get node list from partition"""
    try:
        result = subprocess.run(['scontrol', 'show', 'partition', partition_name], 
                              capture_output=True, text=True, check=True)
        
        for line in result.stdout.split('\n'):
            if line.strip().startswith('Nodes='):
                return line.split('=', 1)[1].strip()
        
        raise ValueError(f"No nodes found in partition {partition_name}")
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Failed to get partition info: {e}")

def parse_node_info(node_list: str) -> List[NodeInfo]:
    """Parse scontrol show node output"""
    try:
        result = subprocess.run(['scontrol', 'show', 'node', node_list], 
                              capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"Failed to get node info: {e}")
    
    nodes = []
    current_node = {}
    
    for line in result.stdout.split('\n'):
        line = line.strip()
        if not line:
            continue
            
        if line.startswith('NodeName='):
            # Save previous node if exists
            if current_node:
                nodes.append(create_node_from_dict(current_node))
                current_node = {}
            
            # Parse NodeName
            match = re.search(r'NodeName=(\S+)', line)
            if match:
                current_node['name'] = match.group(1)
        
        # Parse other fields
        for field, pattern in [
            ('cpu_efctv', r'CPUEfctv=(\d+)'),
            ('cpu_load', r'CPULoad=(\S+)'),
            ('gres', r'Gres=(\S+)'),
            ('real_memory', r'RealMemory=(\d+)'),
            ('free_mem', r'FreeMem=(\d+)'),
            ('state', r'State=(\S+)'),
        ]:
            match = re.search(pattern, line)
            if match:
                current_node[field] = match.group(1)
        
        # Handle AllocTRES specially as it can span multiple fields
        match = re.search(r'AllocTRES=(.+)', line)
        if match:
            current_node['alloc_tres'] = match.group(1)
    
    # Don't forget the last node
    if current_node:
        nodes.append(create_node_from_dict(current_node))
    
    return nodes

def create_node_from_dict(node_dict: dict) -> NodeInfo:
    """Create NodeInfo object from parsed dictionary"""
    return NodeInfo(
        name=node_dict.get('name', ''),
        cpu_efctv=int(node_dict.get('cpu_efctv', 0)),
        cpu_load=float(node_dict.get('cpu_load', 0.0)),
        gres=node_dict.get('gres', ''),
        real_memory=int(node_dict.get('real_memory', 0)),
        free_mem=int(node_dict.get('free_mem', 0)),
        state=node_dict.get('state', ''),
        alloc_tres=node_dict.get('alloc_tres', '')
    )

def print_nodes(nodes: List[NodeInfo], show_available: bool = False):
    """Print nodes in formatted table
    
    Args:
        nodes: List of NodeInfo objects
        show_available: If True, show available (free) resources instead of unallocated
    """
    # Filter out nodes with DOWN state
    filtered_nodes = [node for node in nodes if 'DOWN' not in node.state]
    
    # Sort by: unallocated GPUs (desc), unallocated CPUs (desc), free memory (desc)
    if show_available:
        sorted_nodes = sorted(filtered_nodes, 
                             key=lambda n: (-n.unallocated_gpus, -n.unallocated_cpus, n.used_memory_gb))  # Sort by used memory ascending (less used = better)
        cpu_header = "UnallocCPU"
        mem_header = "UnallocMem(GB)"
    else:
        sorted_nodes = sorted(filtered_nodes, 
                             key=lambda n: (-n.unallocated_gpus, -n.unallocated_cpus, -n.unallocated_memory_gb))
        cpu_header = "UnallocCPU"
        mem_header = "UnallocMem(GB)"
    
    # Print header
    if show_available:
        print(f"{'NodeName':<20} {'UnallocGPU':<10} {cpu_header:<10} {mem_header:<14} {'CPULoad':<8} {'UsedMem(GB)':<11} {'Gres':<25} {'State':<15} {'AllocTRES'}")
        print(f"{'--------':<20} {'----------':<10} {'----------':<10} {'--------------':<14} {'--------':<8} {'-----------':<11} {'----':<25} {'-----':<15} {'--------'}")
    else:
        print(f"{'NodeName':<20} {'UnallocGPU':<10} {cpu_header:<10} {mem_header:<14} {'Gres':<25} {'State':<15} {'AllocTRES'}")
        print(f"{'--------':<20} {'----------':<10} {'----------':<10} {'--------------':<14} {'----':<25} {'-----':<15} {'--------'}")
    
    # Print each node
    for node in sorted_nodes:
        if show_available:
            print(f"{node.name:<20} {node.unallocated_gpus:<10} {node.unallocated_cpus:<10} {node.unallocated_memory_gb:<14.1f} {node.cpu_load:<8.1f} {node.used_memory_gb:<11.1f} {node.clean_gres:<25} {node.state:<15} {node.alloc_tres}")
        else:
            print(f"{node.name:<20} {node.unallocated_gpus:<10} {node.unallocated_cpus:<10} {node.unallocated_memory_gb:<14.1f} {node.clean_gres:<25} {node.state:<15} {node.alloc_tres}")

def main():
    """Main function"""
    parser = argparse.ArgumentParser(description='Display SLURM node allocation information')
    parser.add_argument('--available', '-a', action='store_true', 
                       help='Show available (free) CPU and memory instead of unallocated')
    parser.add_argument('--partition', '-p', default='seas_gpu',
                       help='Partition to query (default: seas_gpu)')
    
    args = parser.parse_args()
    
    try:
        # Get nodes from seas_gpu partition
        node_list = get_partition_nodes(args.partition)
        
        # Parse node information
        nodes = parse_node_info(node_list)
        
        # Print sorted results
        print_nodes(nodes, show_available=args.available)
        
    except Exception as e:
        print(f"Error: {e}")
        return 1
    
    return 0

if __name__ == "__main__":
    exit(main()) 