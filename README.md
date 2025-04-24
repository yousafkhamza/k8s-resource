# Kubernetes Resource Analyzer

A command-line tool to analyze resource utilization in Kubernetes clusters. This tool helps you understand your cluster's resource usage, identify under/over provisioned resources, and check capacity for new jobs.

## Features

- Cluster-wide resource overview showing total CPU and memory usage
- Node-specific resource details with used, free, and total resources
- Provisioning assessment to identify under/over utilized resources
- Job resource availability checker to find suitable nodes for specific workloads
- Robust error handling and fallback mechanisms for different cluster configurations

## Installation

### Option 1: One-line installer (recommended)

```bash
curl -sL https://raw.githubusercontent.com/yousafkhamza/k8s-resource/main/install.sh | bash
```

### Option 2: Manual installation

1. Download the script

```bash
curl -sL https://raw.githubusercontent.com/yousafkhamza/k8s-resource/main/k8s-resource.sh -o /usr/local/bin/k8s-resource
```

2. Make it executable

```bash
chmod +x /usr/local/bin/k8s-resource
```

## Requirements

- `kubectl` with access to your Kubernetes cluster
- `jq` for JSON processing
- `bc` for calculations

## Usage

```bash
# Run full analysis
k8s-resource

# Show only cluster overview
k8s-resource --overview

# Show only node details
k8s-resource --nodes

# Skip directly to job resource check
k8s-resource --job

# Get help
k8s-resource --help
```

## Command-line Options

- `-h, --help`: Display help message
- `-v, --version`: Display version information
- `-o, --overview`: Show only cluster-wide resource overview
- `-n, --nodes`: Show only node-specific resource details
- `-j, --job`: Start directly with job resource availability check
- `--no-cleanup`: Keep temporary JSON files after execution

## Examples

### Cluster overview analysis

```bash
$ k8s-resource --overview

Cluster-wide Resource Overview:
---------------------------------------------------------------------------
Resource        Total           Used            Available       Utilization %
---------------------------------------------------------------------------
CPU             48.00 cores     12.75 cores     35.25 cores     26.56%
Memory          192.00 GB       58.43 GB        133.57 GB       30.43%
---------------------------------------------------------------------------

Cluster Provisioning Assessment:
CPU: Potentially UNDER-UTILIZED (< 30% usage)
Memory: OPTIMALLY provisioned (30-80% usage)
```

### Job resource check

```bash
$ k8s-resource --job
Enter required CPU cores: 4
Enter required memory (GB): 16

Checking capacity for job requiring 4 CPU cores and 16 GB memory...
Nodes with sufficient resources:
------------------------------------------------------------------------------------
Node Name                                                  CPU Available Mem Available (GB)
------------------------------------------------------------------------------------
node-pool-1-abc123                                         7.80         28.50
node-pool-2-def456                                         6.25         22.10
------------------------------------------------------------------------------------
```

## License

[MIT License](LICENSE)
