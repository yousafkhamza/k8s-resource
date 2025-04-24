#!/bin/bash

VERSION="1.0.0"

# Help function
show_help() {
    cat << EOF
NAME
    k8s-resource - Kubernetes Resource Analyzer

SYNOPSIS
    k8s-resource [OPTION]

DESCRIPTION
    Analyze and display Kubernetes cluster resource utilization.
    This tool provides an overview of CPU and memory usage across nodes,
    helps identify over/under-provisioned resources, and checks if specific
    job requirements can be satisfied by available nodes.

OPTIONS
    -h, --help      Display this help message and exit
    -v, --version   Display version information and exit
    -o, --overview  Show only cluster-wide resource overview
    -n, --nodes     Show only node-specific resource details
    -j, --job       Start directly with job resource availability check
    --no-cleanup    Keep temporary JSON files after execution

REQUIREMENTS
    - kubectl (configured with access to your cluster)
    - jq (for JSON processing)
    
AUTHOR
    Yousaf [https://yousafkhamza.github.io]

VERSION
    $VERSION
EOF
}

# Version function
show_version() {
    echo "k8s-resource version $VERSION"
}

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl could not be found. Please install it first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq could not be found. Please install it first."
    exit 1
fi

# Initialize variables
SHOW_OVERVIEW=true
SHOW_NODES=true
DO_JOB_CHECK=false
DO_CLEANUP=true

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -o|--overview)
            SHOW_OVERVIEW=true
            SHOW_NODES=false
            shift
            ;;
        -n|--nodes)
            SHOW_OVERVIEW=false
            SHOW_NODES=true
            shift
            ;;
        -j|--job)
            DO_JOB_CHECK=true
            shift
            ;;
        --no-cleanup)
            DO_CLEANUP=false
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run 'k8s-resource --help' for usage information."
            exit 1
            ;;
    esac
done

# Function to get node metrics
get_node_metrics() {
    echo "Gathering cluster metrics..."

    # Get current resource usage - redirecting errors to /dev/null
    kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | jq '.items[] | {name: .metadata.name, cpu_usage_cores: ((.usage.cpu | sub("n"; "") | tonumber) / 1000000000), memory_usage_GB: ((.usage.memory | sub("Ki"; "") | tonumber) / 1048576)}' 2>/dev/null > usage.json

    # Get allocatable resources - redirecting errors to /dev/null
    kubectl get nodes -o json 2>/dev/null | jq '.items[] | {name: .metadata.name, allocatable_cpu_cores: (.status.allocatable.cpu | sub("m"; "") | tonumber / 1000), allocatable_memory_GB: (.status.allocatable.memory | sub("Ki"; "") | tonumber / 1048576)}' 2>/dev/null > allocatable.json

    # Combine the data - redirecting errors to /dev/null
    jq -s 'flatten | group_by(.name) | map(add)' usage.json allocatable.json 2>/dev/null > combined.json

    # Create a backup for direct node extraction in case the combined.json is empty
    if [ ! -s combined.json ]; then
        echo "Using alternative data gathering method..."
        echo "[]" > combined.json

        # Get all nodes directly
        kubectl get nodes -o wide | tail -n +2 | while read -r node rest; do
            # Extract data with error redirection
            cpu_usage=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/$node 2>/dev/null | jq -r '.usage.cpu' 2>/dev/null || echo "0")
            cpu_allocatable=$(kubectl get node $node -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null || echo "0")
            memory_usage=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/$node 2>/dev/null | jq -r '.usage.memory' 2>/dev/null || echo "0")
            memory_allocatable=$(kubectl get node $node -o jsonpath='{.status.allocatable.memory}' 2>/dev/null || echo "0")

            # Default values (in case of errors)
            cpu_usage_cores=0
            cpu_allocatable_cores=0
            memory_usage_gb=0
            memory_allocatable_gb=0

            # Try to convert values - suppress errors
            cpu_usage_cores=$(echo $cpu_usage | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1/1000}' 2>/dev/null || echo "0.000")
            cpu_allocatable_cores=$(echo $cpu_allocatable | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1}' 2>/dev/null || echo "0.000")
            memory_usage_gb=$(echo $memory_usage | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1/1048576}' 2>/dev/null || echo "0.000")
            memory_allocatable_gb=$(echo $memory_allocatable | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1/1048576}' 2>/dev/null || echo "0.000")

            # Add to combined.json silently
            tmp_file=$(mktemp)
            jq --arg name "$node" \
               --arg cpu_used "$cpu_usage_cores" \
               --arg cpu_total "$cpu_allocatable_cores" \
               --arg mem_used "$memory_usage_gb" \
               --arg mem_total "$memory_allocatable_gb" \
               '. + [{"name": $name, "cpu_used": $cpu_used, "cpu_total": $cpu_total, "mem_used": $mem_used, "mem_total": $mem_total}]' \
               combined.json > "$tmp_file" 2>/dev/null && mv "$tmp_file" combined.json
        done
    fi
}

# Function to create a separator line of appropriate length
create_separator() {
    local length=$1
    printf '%*s\n' "$length" | tr ' ' '-'
}

# Function to display cluster-wide resource usage
display_cluster_overview() {
    echo -e "\nCluster-wide Resource Overview:"
    
    # Calculate the format string and total width
    local format="%-15s %-15s %-15s %-15s %-15s"
    local total_width=75  # Sum of all column widths including spaces

    # Create separator
    local separator=$(create_separator $total_width)
    
    echo "$separator"
    printf "$format\n" "Resource" "Total" "Used" "Available" "Utilization %"
    echo "$separator"
    
    # Calculate total cluster resources
    local total_cpu=0
    local used_cpu=0
    local total_memory=0
    local used_memory=0
    
    # Add error suppression
    while read -r line; do
        cpu_total=$(echo "$line" | cut -f3)
        cpu_used=$(echo "$line" | cut -f1)
        memory_total=$(echo "$line" | cut -f4)
        memory_used=$(echo "$line" | cut -f2)
        
        # Ensure we only count positive values for total
        if (( $(echo "$cpu_total > 0" | bc -l) )); then
            total_cpu=$(echo "$total_cpu + $cpu_total" | bc)
        fi
        used_cpu=$(echo "$used_cpu + $cpu_used" | bc)
        
        if (( $(echo "$memory_total > 0" | bc -l) )); then
            total_memory=$(echo "$total_memory + $memory_total" | bc)
        fi
        used_memory=$(echo "$used_memory + $memory_used" | bc)
    done < <(jq -r '
    def null_to_zero(v): if v == null then 0 else v end;
    .[] | 
    . as $node |
    {
        cpu_used: (null_to_zero($node.cpu_usage_cores) // null_to_zero($node.cpu_used)),
        mem_used: (null_to_zero($node.memory_usage_GB) // null_to_zero($node.mem_used)),
        cpu_total: (null_to_zero($node.allocatable_cpu_cores) // null_to_zero($node.cpu_total)),
        mem_total: (null_to_zero($node.allocatable_memory_GB) // null_to_zero($node.mem_total))
    } | [.cpu_used, .mem_used, .cpu_total, .mem_total] | @tsv' combined.json 2>/dev/null)
    
    # Calculate available resources and utilization percentages
    cpu_available=$(echo "$total_cpu - $used_cpu" | bc)
    memory_available=$(echo "$total_memory - $used_memory" | bc)
    
    # Avoid division by zero
    if (( $(echo "$total_cpu > 0" | bc -l) )); then
        cpu_util=$(echo "scale=2; ($used_cpu / $total_cpu) * 100" | bc -l)
    else
        cpu_util="0.00"
    fi
    
    if (( $(echo "$total_memory > 0" | bc -l) )); then
        memory_util=$(echo "scale=2; ($used_memory / $total_memory) * 100" | bc -l)
    else
        memory_util="0.00"
    fi
    
    # Format all values
    total_cpu=$(printf "%.2f cores" "${total_cpu:-0}" 2>/dev/null || echo "0.00 cores")
    used_cpu=$(printf "%.2f cores" "${used_cpu:-0}" 2>/dev/null || echo "0.00 cores")
    cpu_available=$(printf "%.2f cores" "${cpu_available:-0}" 2>/dev/null || echo "0.00 cores")
    cpu_util=$(printf "%.2f%%" "${cpu_util:-0}" 2>/dev/null || echo "0.00%")
    
    total_memory=$(printf "%.2f GB" "${total_memory:-0}" 2>/dev/null || echo "0.00 GB")
    used_memory=$(printf "%.2f GB" "${used_memory:-0}" 2>/dev/null || echo "0.00 GB")
    memory_available=$(printf "%.2f GB" "${memory_available:-0}" 2>/dev/null || echo "0.00 GB")
    memory_util=$(printf "%.2f%%" "${memory_util:-0}" 2>/dev/null || echo "0.00%")
    
    # Display the results
    printf "$format\n" "CPU" "$total_cpu" "$used_cpu" "$cpu_available" "$cpu_util"
    printf "$format\n" "Memory" "$total_memory" "$used_memory" "$memory_available" "$memory_util"
    echo "$separator"
    
    # Provisioning assessment
    echo -e "\nCluster Provisioning Assessment:"
    
    # Extract numeric values for comparison
    cpu_util_num=$(echo "$cpu_util" | sed 's/%//')
    memory_util_num=$(echo "$memory_util" | sed 's/%//')
    
    # CPU assessment - fixed comparison
    echo -n "CPU: "
    if (( $(echo "$cpu_util_num < 30" | bc -l) )); then
        echo "Potentially UNDER-UTILIZED (< 30% usage)"
    elif (( $(echo "$cpu_util_num > 80" | bc -l) )); then
        echo "Potentially OVER-PROVISIONED (> 80% usage)"
    else
        echo "OPTIMALLY provisioned (30-80% usage)"
    fi
    
    # Memory assessment - fixed comparison
    echo -n "Memory: "
    if (( $(echo "$memory_util_num < 30" | bc -l) )); then
        echo "Potentially UNDER-UTILIZED (< 30% usage)"
    elif (( $(echo "$memory_util_num > 80" | bc -l) )); then
        echo "Potentially OVER-PROVISIONED (> 80% usage)"
    else
        echo "OPTIMALLY provisioned (30-80% usage)"
    fi
}

# Function to display resource availability
display_resources() {
    echo -e "\nNode Resource Availability:"

    # Calculate the format string and total width - increased node name column width
    local format="%-60s %-12s %-12s %-12s %-12s %-12s %-12s"
    local total_width=132  # Sum of all column widths including spaces

    # Create separator dynamically
    local separator=$(create_separator $total_width)

    echo "$separator"
    # Header format aligned properly
    printf "$format\n" "Node Name" "CPU (Used)" "CPU (Free)" "CPU (Total)" "Mem (Used)" "Mem (Free)" "Mem (Total)"
    echo "$separator"

    # Add error suppression to all JQ commands
    jq -r '
    def null_to_zero(v): if v == null then 0 else v end;
    .[] |
    . as $node |
    {
        name: $node.name,
        cpu_used: (null_to_zero($node.cpu_usage_cores) // null_to_zero($node.cpu_used)),
        cpu_total: (null_to_zero($node.allocatable_cpu_cores) // null_to_zero($node.cpu_total)),
        mem_used: (null_to_zero($node.memory_usage_GB) // null_to_zero($node.mem_used)),
        mem_total: (null_to_zero($node.allocatable_memory_GB) // null_to_zero($node.mem_total))
    } |
    . as $data |
    {
        name: $data.name,
        cpu_used: $data.cpu_used,
        cpu_free: (if $data.name | startswith("fargate-") then $data.cpu_total else ($data.cpu_total - $data.cpu_used) end),
        cpu_total: $data.cpu_total,
        mem_used: $data.mem_used,
        mem_free: (if $data.name | startswith("fargate-") then $data.mem_total - $data.mem_used else ($data.mem_total - $data.mem_used) end),
        mem_total: $data.mem_total
    } |
    [
        .name,
        .cpu_used,
        .cpu_free,
        .cpu_total,
        .mem_used,
        .mem_free,
        .mem_total
    ] | @tsv' combined.json 2>/dev/null | while IFS=$'\t' read -r name cpu_used cpu_free cpu_total mem_used mem_free mem_total; do
        # Special handling for Fargate nodes - ensure totals match used+free
        if [[ "$name" == fargate-* ]]; then
            # For Fargate nodes, if total is near zero but used isn't, adjust the total
            if (( $(echo "$cpu_total < 0.1 && $cpu_used > 0" | bc -l) )); then
                cpu_total=$(echo "$cpu_used" | bc -l)
            fi
            # Ensure free is calculated correctly based on total and used
            cpu_free=$(echo "$cpu_total - $cpu_used" | bc -l)
            
            # Same for memory
            if (( $(echo "$mem_free < 0" | bc -l) )); then
                mem_free=0
                mem_total=$(echo "$mem_used + $mem_free" | bc -l)
            fi
        fi
        
        # Format all values to 2 decimal places
        cpu_used=$(printf "%.2f" "${cpu_used:-0}" 2>/dev/null || echo "0.00")
        cpu_free=$(printf "%.2f" "${cpu_free:-0}" 2>/dev/null || echo "0.00")
        cpu_total=$(printf "%.2f" "${cpu_total:-0}" 2>/dev/null || echo "0.00")
        mem_used=$(printf "%.2f" "${mem_used:-0}" 2>/dev/null || echo "0.00")
        mem_free=$(printf "%.2f" "${mem_free:-0}" 2>/dev/null || echo "0.00")
        mem_total=$(printf "%.2f" "${mem_total:-0}" 2>/dev/null || echo "0.00")

        printf "$format\n" \
            "$name" "$cpu_used" "$cpu_free" "$cpu_total" "$mem_used" "$mem_free" "$mem_total"
    done

    echo "$separator"
}

# Function to check if resources are available for a specific job
check_job_resources() {
    read -p "Enter required CPU cores: " required_cpu
    read -p "Enter required memory (GB): " required_mem

    echo -e "\nChecking capacity for job requiring $required_cpu CPU cores and $required_mem GB memory..."
    echo "Nodes with sufficient resources:"

    # Calculate format and width for the job resources table - increased node name width
    local format="%-60s %-12s %-12s"
    local total_width=84  # Sum of column widths including spaces

    # Create separator dynamically
    local separator=$(create_separator $total_width)

    echo "$separator"
    printf "$format\n" "Node Name" "CPU Available" "Mem Available (GB)"
    echo "$separator"

    # Add error suppression
    jq -r --arg rc "$required_cpu" --arg rm "$required_mem" '
    def null_to_zero(v): if v == null then 0 else v end;
    .[] |
    . as $node |
    {
        name: $node.name,
        cpu_used: (null_to_zero($node.cpu_usage_cores) // null_to_zero($node.cpu_used)),
        cpu_total: (null_to_zero($node.allocatable_cpu_cores) // null_to_zero($node.cpu_total)),
        mem_used: (null_to_zero($node.memory_usage_GB) // null_to_zero($node.mem_used)),
        mem_total: (null_to_zero($node.allocatable_memory_GB) // null_to_zero($node.mem_total))
    } |
    . as $data |
    {
        name: $data.name,
        cpu_free: (if $data.name | startswith("fargate-") then $data.cpu_total else ($data.cpu_total - $data.cpu_used) end),
        mem_free: (if $data.name | startswith("fargate-") then $data.mem_total - $data.mem_used else ($data.mem_total - $data.mem_used) end)
    } |
    select(
        .cpu_free >= ($rc | tonumber) and
        .mem_free >= ($rm | tonumber)
    ) |
    [.name, .cpu_free, .mem_free] | @tsv' combined.json 2>/dev/null | while IFS=$'\t' read -r name cpu_free mem_free; do
        cpu_free=$(printf "%.2f" "${cpu_free:-0}" 2>/dev/null || echo "0.00")
        mem_free=$(printf "%.2f" "${mem_free:-0}" 2>/dev/null || echo "0.00")

        printf "$format\n" "$name" "$cpu_free" "$mem_free"
    done

    echo "$separator"
}

# Main execution flow
main() {
    # Gather metrics
    get_node_metrics 2>/dev/null
    
    # Display overview if requested
    if [[ "$SHOW_OVERVIEW" == true ]]; then
        display_cluster_overview
    fi
    
    # Display node details if requested
    if [[ "$SHOW_NODES" == true ]]; then
        display_resources
    fi
    
    # Handle job resource check
    if [[ "$DO_JOB_CHECK" == true ]]; then
        check_job_resources
    else
        # Interactive job resource check prompt
        while true; do
            read -p "Do you want to check if specific job resources are available? (y/n): " yn
            case $yn in
                [Yy]* ) check_job_resources; break;;
                [Nn]* ) break;;
                * ) echo "Please answer yes or no.";;
            esac
        done
    fi
    
    # Cleanup temp files if requested
    if [[ "$DO_CLEANUP" == true ]]; then
        rm -f usage.json allocatable.json combined.json 2>/dev/null
        echo -e "\nDone. Temporary files removed."
    else
        echo -e "\nDone. Temporary files kept: usage.json, allocatable.json, combined.json"
    fi
}

# Execute main function
main#!/bin/bash

VERSION="1.0.0"

# Help function
show_help() {
    cat << EOF
NAME
    k8s-resource - Kubernetes Resource Analyzer

SYNOPSIS
    k8s-resource [OPTION]

DESCRIPTION
    Analyze and display Kubernetes cluster resource utilization.
    This tool provides an overview of CPU and memory usage across nodes,
    helps identify over/under-provisioned resources, and checks if specific
    job requirements can be satisfied by available nodes.

OPTIONS
    -h, --help      Display this help message and exit
    -v, --version   Display version information and exit
    -o, --overview  Show only cluster-wide resource overview
    -n, --nodes     Show only node-specific resource details
    -j, --job       Start directly with job resource availability check
    --no-cleanup    Keep temporary JSON files after execution

REQUIREMENTS
    - kubectl (configured with access to your cluster)
    - jq (for JSON processing)

EXAMPLES
    k8s-resource             Run full analysis with interactive job check prompt
    k8s-resource --overview  Show only cluster-wide resource overview
    k8s-resource --job       Skip to job resource check
    
AUTHOR
    Your organization or name here

VERSION
    $VERSION
EOF
}

# Version function
show_version() {
    echo "k8s-resource version $VERSION"
}

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl could not be found. Please install it first."
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq could not be found. Please install it first."
    exit 1
fi

# Initialize variables
SHOW_OVERVIEW=true
SHOW_NODES=true
DO_JOB_CHECK=false
DO_CLEANUP=true

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        -o|--overview)
            SHOW_OVERVIEW=true
            SHOW_NODES=false
            shift
            ;;
        -n|--nodes)
            SHOW_OVERVIEW=false
            SHOW_NODES=true
            shift
            ;;
        -j|--job)
            DO_JOB_CHECK=true
            shift
            ;;
        --no-cleanup)
            DO_CLEANUP=false
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run 'k8s-resource --help' for usage information."
            exit 1
            ;;
    esac
done

# Function to get node metrics
get_node_metrics() {
    echo "Gathering cluster metrics..."

    # Get current resource usage - redirecting errors to /dev/null
    kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes 2>/dev/null | jq '.items[] | {name: .metadata.name, cpu_usage_cores: ((.usage.cpu | sub("n"; "") | tonumber) / 1000000000), memory_usage_GB: ((.usage.memory | sub("Ki"; "") | tonumber) / 1048576)}' 2>/dev/null > usage.json

    # Get allocatable resources - redirecting errors to /dev/null
    kubectl get nodes -o json 2>/dev/null | jq '.items[] | {name: .metadata.name, allocatable_cpu_cores: (.status.allocatable.cpu | sub("m"; "") | tonumber / 1000), allocatable_memory_GB: (.status.allocatable.memory | sub("Ki"; "") | tonumber / 1048576)}' 2>/dev/null > allocatable.json

    # Combine the data - redirecting errors to /dev/null
    jq -s 'flatten | group_by(.name) | map(add)' usage.json allocatable.json 2>/dev/null > combined.json

    # Create a backup for direct node extraction in case the combined.json is empty
    if [ ! -s combined.json ]; then
        echo "Using alternative data gathering method..."
        echo "[]" > combined.json

        # Get all nodes directly
        kubectl get nodes -o wide | tail -n +2 | while read -r node rest; do
            # Extract data with error redirection
            cpu_usage=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/$node 2>/dev/null | jq -r '.usage.cpu' 2>/dev/null || echo "0")
            cpu_allocatable=$(kubectl get node $node -o jsonpath='{.status.allocatable.cpu}' 2>/dev/null || echo "0")
            memory_usage=$(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/$node 2>/dev/null | jq -r '.usage.memory' 2>/dev/null || echo "0")
            memory_allocatable=$(kubectl get node $node -o jsonpath='{.status.allocatable.memory}' 2>/dev/null || echo "0")

            # Default values (in case of errors)
            cpu_usage_cores=0
            cpu_allocatable_cores=0
            memory_usage_gb=0
            memory_allocatable_gb=0

            # Try to convert values - suppress errors
            cpu_usage_cores=$(echo $cpu_usage | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1/1000}' 2>/dev/null || echo "0.000")
            cpu_allocatable_cores=$(echo $cpu_allocatable | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1}' 2>/dev/null || echo "0.000")
            memory_usage_gb=$(echo $memory_usage | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1/1048576}' 2>/dev/null || echo "0.000")
            memory_allocatable_gb=$(echo $memory_allocatable | sed 's/[^0-9.]//g' | awk '{printf "%.2f", $1/1048576}' 2>/dev/null || echo "0.000")

            # Add to combined.json silently
            tmp_file=$(mktemp)
            jq --arg name "$node" \
               --arg cpu_used "$cpu_usage_cores" \
               --arg cpu_total "$cpu_allocatable_cores" \
               --arg mem_used "$memory_usage_gb" \
               --arg mem_total "$memory_allocatable_gb" \
               '. + [{"name": $name, "cpu_used": $cpu_used, "cpu_total": $cpu_total, "mem_used": $mem_used, "mem_total": $mem_total}]' \
               combined.json > "$tmp_file" 2>/dev/null && mv "$tmp_file" combined.json
        done
    fi
}

# Function to create a separator line of appropriate length
create_separator() {
    local length=$1
    printf '%*s\n' "$length" | tr ' ' '-'
}

# Function to display cluster-wide resource usage
display_cluster_overview() {
    echo -e "\nCluster-wide Resource Overview:"
    
    # Calculate the format string and total width
    local format="%-15s %-15s %-15s %-15s %-15s"
    local total_width=75  # Sum of all column widths including spaces

    # Create separator
    local separator=$(create_separator $total_width)
    
    echo "$separator"
    printf "$format\n" "Resource" "Total" "Used" "Available" "Utilization %"
    echo "$separator"
    
    # Calculate total cluster resources
    local total_cpu=0
    local used_cpu=0
    local total_memory=0
    local used_memory=0
    
    # Add error suppression
    while read -r line; do
        cpu_total=$(echo "$line" | cut -f3)
        cpu_used=$(echo "$line" | cut -f1)
        memory_total=$(echo "$line" | cut -f4)
        memory_used=$(echo "$line" | cut -f2)
        
        # Ensure we only count positive values for total
        if (( $(echo "$cpu_total > 0" | bc -l) )); then
            total_cpu=$(echo "$total_cpu + $cpu_total" | bc)
        fi
        used_cpu=$(echo "$used_cpu + $cpu_used" | bc)
        
        if (( $(echo "$memory_total > 0" | bc -l) )); then
            total_memory=$(echo "$total_memory + $memory_total" | bc)
        fi
        used_memory=$(echo "$used_memory + $memory_used" | bc)
    done < <(jq -r '
    def null_to_zero(v): if v == null then 0 else v end;
    .[] | 
    . as $node |
    {
        cpu_used: (null_to_zero($node.cpu_usage_cores) // null_to_zero($node.cpu_used)),
        mem_used: (null_to_zero($node.memory_usage_GB) // null_to_zero($node.mem_used)),
        cpu_total: (null_to_zero($node.allocatable_cpu_cores) // null_to_zero($node.cpu_total)),
        mem_total: (null_to_zero($node.allocatable_memory_GB) // null_to_zero($node.mem_total))
    } | [.cpu_used, .mem_used, .cpu_total, .mem_total] | @tsv' combined.json 2>/dev/null)
    
    # Calculate available resources and utilization percentages
    cpu_available=$(echo "$total_cpu - $used_cpu" | bc)
    memory_available=$(echo "$total_memory - $used_memory" | bc)
    
    # Avoid division by zero
    if (( $(echo "$total_cpu > 0" | bc -l) )); then
        cpu_util=$(echo "scale=2; ($used_cpu / $total_cpu) * 100" | bc -l)
    else
        cpu_util="0.00"
    fi
    
    if (( $(echo "$total_memory > 0" | bc -l) )); then
        memory_util=$(echo "scale=2; ($used_memory / $total_memory) * 100" | bc -l)
    else
        memory_util="0.00"
    fi
    
    # Format all values
    total_cpu=$(printf "%.2f cores" "${total_cpu:-0}" 2>/dev/null || echo "0.00 cores")
    used_cpu=$(printf "%.2f cores" "${used_cpu:-0}" 2>/dev/null || echo "0.00 cores")
    cpu_available=$(printf "%.2f cores" "${cpu_available:-0}" 2>/dev/null || echo "0.00 cores")
    cpu_util=$(printf "%.2f%%" "${cpu_util:-0}" 2>/dev/null || echo "0.00%")
    
    total_memory=$(printf "%.2f GB" "${total_memory:-0}" 2>/dev/null || echo "0.00 GB")
    used_memory=$(printf "%.2f GB" "${used_memory:-0}" 2>/dev/null || echo "0.00 GB")
    memory_available=$(printf "%.2f GB" "${memory_available:-0}" 2>/dev/null || echo "0.00 GB")
    memory_util=$(printf "%.2f%%" "${memory_util:-0}" 2>/dev/null || echo "0.00%")
    
    # Display the results
    printf "$format\n" "CPU" "$total_cpu" "$used_cpu" "$cpu_available" "$cpu_util"
    printf "$format\n" "Memory" "$total_memory" "$used_memory" "$memory_available" "$memory_util"
    echo "$separator"
    
    # Provisioning assessment
    echo -e "\nCluster Provisioning Assessment:"
    
    # Extract numeric values for comparison
    cpu_util_num=$(echo "$cpu_util" | sed 's/%//')
    memory_util_num=$(echo "$memory_util" | sed 's/%//')
    
    # CPU assessment - fixed comparison
    echo -n "CPU: "
    if (( $(echo "$cpu_util_num < 30" | bc -l) )); then
        echo "Potentially UNDER-UTILIZED (< 30% usage)"
    elif (( $(echo "$cpu_util_num > 80" | bc -l) )); then
        echo "Potentially OVER-PROVISIONED (> 80% usage)"
    else
        echo "OPTIMALLY provisioned (30-80% usage)"
    fi
    
    # Memory assessment - fixed comparison
    echo -n "Memory: "
    if (( $(echo "$memory_util_num < 30" | bc -l) )); then
        echo "Potentially UNDER-UTILIZED (< 30% usage)"
    elif (( $(echo "$memory_util_num > 80" | bc -l) )); then
        echo "Potentially OVER-PROVISIONED (> 80% usage)"
    else
        echo "OPTIMALLY provisioned (30-80% usage)"
    fi
}

# Function to display resource availability
display_resources() {
    echo -e "\nNode Resource Availability:"

    # Calculate the format string and total width - increased node name column width
    local format="%-60s %-12s %-12s %-12s %-12s %-12s %-12s"
    local total_width=132  # Sum of all column widths including spaces

    # Create separator dynamically
    local separator=$(create_separator $total_width)

    echo "$separator"
    # Header format aligned properly
    printf "$format\n" "Node Name" "CPU (Used)" "CPU (Free)" "CPU (Total)" "Mem (Used)" "Mem (Free)" "Mem (Total)"
    echo "$separator"

    # Add error suppression to all JQ commands
    jq -r '
    def null_to_zero(v): if v == null then 0 else v end;
    .[] |
    . as $node |
    {
        name: $node.name,
        cpu_used: (null_to_zero($node.cpu_usage_cores) // null_to_zero($node.cpu_used)),
        cpu_total: (null_to_zero($node.allocatable_cpu_cores) // null_to_zero($node.cpu_total)),
        mem_used: (null_to_zero($node.memory_usage_GB) // null_to_zero($node.mem_used)),
        mem_total: (null_to_zero($node.allocatable_memory_GB) // null_to_zero($node.mem_total))
    } |
    . as $data |
    {
        name: $data.name,
        cpu_used: $data.cpu_used,
        cpu_free: (if $data.name | startswith("fargate-") then $data.cpu_total else ($data.cpu_total - $data.cpu_used) end),
        cpu_total: $data.cpu_total,
        mem_used: $data.mem_used,
        mem_free: (if $data.name | startswith("fargate-") then $data.mem_total - $data.mem_used else ($data.mem_total - $data.mem_used) end),
        mem_total: $data.mem_total
    } |
    [
        .name,
        .cpu_used,
        .cpu_free,
        .cpu_total,
        .mem_used,
        .mem_free,
        .mem_total
    ] | @tsv' combined.json 2>/dev/null | while IFS=$'\t' read -r name cpu_used cpu_free cpu_total mem_used mem_free mem_total; do
        # Special handling for Fargate nodes - ensure totals match used+free
        if [[ "$name" == fargate-* ]]; then
            # For Fargate nodes, if total is near zero but used isn't, adjust the total
            if (( $(echo "$cpu_total < 0.1 && $cpu_used > 0" | bc -l) )); then
                cpu_total=$(echo "$cpu_used" | bc -l)
            fi
            # Ensure free is calculated correctly based on total and used
            cpu_free=$(echo "$cpu_total - $cpu_used" | bc -l)
            
            # Same for memory
            if (( $(echo "$mem_free < 0" | bc -l) )); then
                mem_free=0
                mem_total=$(echo "$mem_used + $mem_free" | bc -l)
            fi
        fi
        
        # Format all values to 2 decimal places
        cpu_used=$(printf "%.2f" "${cpu_used:-0}" 2>/dev/null || echo "0.00")
        cpu_free=$(printf "%.2f" "${cpu_free:-0}" 2>/dev/null || echo "0.00")
        cpu_total=$(printf "%.2f" "${cpu_total:-0}" 2>/dev/null || echo "0.00")
        mem_used=$(printf "%.2f" "${mem_used:-0}" 2>/dev/null || echo "0.00")
        mem_free=$(printf "%.2f" "${mem_free:-0}" 2>/dev/null || echo "0.00")
        mem_total=$(printf "%.2f" "${mem_total:-0}" 2>/dev/null || echo "0.00")

        printf "$format\n" \
            "$name" "$cpu_used" "$cpu_free" "$cpu_total" "$mem_used" "$mem_free" "$mem_total"
    done

    echo "$separator"
}

# Function to check if resources are available for a specific job
check_job_resources() {
    read -p "Enter required CPU cores: " required_cpu
    read -p "Enter required memory (GB): " required_mem

    echo -e "\nChecking capacity for job requiring $required_cpu CPU cores and $required_mem GB memory..."
    echo "Nodes with sufficient resources:"

    # Calculate format and width for the job resources table - increased node name width
    local format="%-60s %-12s %-12s"
    local total_width=84  # Sum of column widths including spaces

    # Create separator dynamically
    local separator=$(create_separator $total_width)

    echo "$separator"
    printf "$format\n" "Node Name" "CPU Available" "Mem Available (GB)"
    echo "$separator"

    # Add error suppression
    jq -r --arg rc "$required_cpu" --arg rm "$required_mem" '
    def null_to_zero(v): if v == null then 0 else v end;
    .[] |
    . as $node |
    {
        name: $node.name,
        cpu_used: (null_to_zero($node.cpu_usage_cores) // null_to_zero($node.cpu_used)),
        cpu_total: (null_to_zero($node.allocatable_cpu_cores) // null_to_zero($node.cpu_total)),
        mem_used: (null_to_zero($node.memory_usage_GB) // null_to_zero($node.mem_used)),
        mem_total: (null_to_zero($node.allocatable_memory_GB) // null_to_zero($node.mem_total))
    } |
    . as $data |
    {
        name: $data.name,
        cpu_free: (if $data.name | startswith("fargate-") then $data.cpu_total else ($data.cpu_total - $data.cpu_used) end),
        mem_free: (if $data.name | startswith("fargate-") then $data.mem_total - $data.mem_used else ($data.mem_total - $data.mem_used) end)
    } |
    select(
        .cpu_free >= ($rc | tonumber) and
        .mem_free >= ($rm | tonumber)
    ) |
    [.name, .cpu_free, .mem_free] | @tsv' combined.json 2>/dev/null | while IFS=$'\t' read -r name cpu_free mem_free; do
        cpu_free=$(printf "%.2f" "${cpu_free:-0}" 2>/dev/null || echo "0.00")
        mem_free=$(printf "%.2f" "${mem_free:-0}" 2>/dev/null || echo "0.00")

        printf "$format\n" "$name" "$cpu_free" "$mem_free"
    done

    echo "$separator"
}

# Main execution flow
main() {
    # Gather metrics
    get_node_metrics 2>/dev/null
    
    # Display overview if requested
    if [[ "$SHOW_OVERVIEW" == true ]]; then
        display_cluster_overview
    fi
    
    # Display node details if requested
    if [[ "$SHOW_NODES" == true ]]; then
        display_resources
    fi
    
    # Handle job resource check
    if [[ "$DO_JOB_CHECK" == true ]]; then
        check_job_resources
    else
        # Interactive job resource check prompt
        while true; do
            read -p "Do you want to check if specific job resources are available? (y/n): " yn
            case $yn in
                [Yy]* ) check_job_resources; break;;
                [Nn]* ) break;;
                * ) echo "Please answer yes or no.";;
            esac
        done
    fi
    
    # Cleanup temp files if requested
    if [[ "$DO_CLEANUP" == true ]]; then
        rm -f usage.json allocatable.json combined.json 2>/dev/null
        echo -e "\nDone. Temporary files removed."
    else
        echo -e "\nDone. Temporary files kept: usage.json, allocatable.json, combined.json"
    fi
}

# Execute main function
main