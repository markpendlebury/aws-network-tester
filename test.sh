#!/bin/bash

# Test Configuration
BANDWIDTH_GBPS=100
PARALLEL_STREAMS=8
TEST_DURATION=30
BUFFER_SIZE="128K"

# TCP Buffer Size
RMEM_MAX=16777216
WMEM_MAX=16777216
TCP_RMEM="4096 87380 16777216"
TCP_WMEM="4096 87380 16777216"

# Install prerequisites
setup_tools() {
    required_packages=(iperf3 ethtool bc numactl)

    for package in "${required_packages[@]}"; do
        if ! command -v $package &>/dev/null; then
            echo "$package could not be found, installing..."
            sudo yum install $package -y
        fi
    done
}

# Optimize network interface
optimize_interface() {
    interface=$(ip route | grep default | awk '{print $5}')
    echo "Optimizing interface: $interface"

    # Increase ring buffer sizes
    sudo ethtool -G $interface rx 4096 tx 4096 || true

    # Enable offloading features
    sudo ethtool -K $interface tso on gso on gro on || true

    # Set adaptive interrupt coalescing
    sudo ethtool -C $interface adaptive-rx on adaptive-tx on || true

    # Set Jumbo frames
    sudo ip link set dev $interface mtu 9000 || true

    # Show current interface settings
    echo "Current interface settings:"
    ethtool -g $interface
    ethtool -k $interface
}

# Function to measure RTT
measure_rtt() {
    local target_ip=$1
    local samples=5

    # Get RTT value directly, no extra output
    rtt=$(ping -c $samples $target_ip 2>/dev/null |
        awk -F '/' 'END{print $5}')

    # Validate and ensure we have a number
    if [[ ! "$rtt" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        rtt="1.000"
    fi

    # Convert to seconds and output ONLY the number
    bc <<<"scale=6; $rtt/1000"
}

# Calculate optimal window size
calculate_window() {
    local bandwidth_gbps=$1
    local rtt_sec=$2

    # Validate inputs
    if [[ ! "$bandwidth_gbps" =~ ^[0-9]+$ ]] || [[ ! "$rtt_sec" =~ ^[0-9.]+$ ]]; then
        echo "ERROR: Invalid inputs"
        return 1
    fi

    # Calculate bits per second
    local bits_per_sec=$(echo "$bandwidth_gbps * 1000 * 1000 * 1000" | bc)

    # Calculate window size
    local window_size=$(echo "scale=0; ($bits_per_sec * $rtt_sec) / 8" | bc)

    echo "Calculating optimal TCP window size:"
    echo "- Bandwidth: $bandwidth_gbps Gbps"
    echo "- RTT: $(echo "scale=3; $rtt_sec * 1000" | bc) ms"
    echo "- Calculated window size: $window_size bytes ($(echo "scale=2; $window_size/1024/1024" | bc) MB)"

    # Calculate power of 2
    local power=1
    while [ "$window_size" -gt 0 ] && [ $power -lt $window_size ]; do
        power=$((power * 2))
    done

    echo "- Rounded window size: $power bytes ($(echo "scale=2; $power/1024/1024" | bc) MB)"
    echo

    echo "$power"
}

# Apply TCP window settings
apply_settings() {
    echo "Applying TCP window settings..."

    # Set minimum, default
    local window_size_min=4096
    local window_size_default=87380
    local window_size_max=$1

    # Maximum allowed value (1GB)
    local max_allowed=$((1024 * 1024 * 1024))

    if [ $window_size_max -gt $max_allowed ]; then
        echo "Warning: Calculated window size too large, limiting to 1GB"
        window_size_max=$max_allowed
    fi

    # Apply advanced TCP settings
    sudo sysctl -w net.core.rmem_max=$window_size_max
    sudo sysctl -w net.core.wmem_max=$window_size_max
    sudo sysctl -w net.ipv4.tcp_rmem="$window_size_min $window_size_default $window_size_max"
    sudo sysctl -w net.ipv4.tcp_wmem="$window_size_min $window_size_default $window_size_max"
    sudo sysctl -w net.ipv4.tcp_window_scaling=1

    # Additional optimizations
    sudo sysctl -w net.core.netdev_max_backlog=250000
    sudo sysctl -w net.core.netdev_budget=600
    sudo sysctl -w net.core.netdev_budget_usecs=6000
    sudo sysctl -w net.ipv4.tcp_low_latency=1
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0
    sudo sysctl -w net.ipv4.tcp_timestamps=1
    sudo sysctl -w net.ipv4.tcp_sack=1
    sudo sysctl -w net.ipv4.tcp_no_metrics_save=1

    echo "Settings applied successfully!"
}

# Optimize system settings
optimize_system() {
    local target_ip=$1

    # Capture RTT
    local rtt_sec=$(measure_rtt $target_ip)

    # Validate RTT
    if [[ ! "$rtt_sec" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Invalid RTT measurement, using default"
        rtt_sec="0.001"
    fi

    local window_size=$(calculate_window $BANDWIDTH_GBPS "$rtt_sec")

    if [ -n "$window_size" ] && [ "$window_size" -gt 0 ]; then
        apply_settings "$window_size"
        echo "$window_size"
    else
        echo "Error in calculations, using default window size"
        apply_settings 16777216
        echo "16777216"
    fi
}

# Run network tests
run_test() {
    local server_ip=$1
    local window_size=$2
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="iperf_test_${timestamp}.log"
    local summary_file="iperf_summary_${timestamp}.txt"

    echo "Starting tests - results will be logged to $log_file"

    # Function to run a single test
    run_single_test() {
        local direction=$1
        local reverse_flag=$2

        echo "Testing $direction Speed..."
        numactl --localalloc iperf3 -c $server_ip \
            -P $PARALLEL_STREAMS \
            -t $TEST_DURATION \
            -l $BUFFER_SIZE \
            -w $window_size \
            --tcp-window-size $window_size \
            -Z \
            $reverse_flag |
            tee -a $log_file |
            grep SUM | grep receiver |
            awk '{print $6}'
    }

    # Run tests with delay between them
    download_speed=$(run_single_test "Download" "-R")
    sleep 5
    upload_speed=$(run_single_test "Upload" "")

    # Create summary
    {
        echo "========================================="
        echo "         IPERF3 TEST SUMMARY"
        echo "========================================="
        echo "Test completed at: $(date)"
        echo "Server IP: $server_ip"
        echo "Parallel Streams: $PARALLEL_STREAMS"
        echo "Buffer Size: $BUFFER_SIZE"
        echo "Window Size: $window_size bytes"
        echo "-----------------------------------------"
        echo "Maximum Download Speed: ${download_speed:-0} Gbits/sec"
        echo "Maximum Upload Speed: ${upload_speed:-0} Gbits/sec"
        echo "========================================="
        echo "CPU Usage during test:"
        top -b -n 1 | grep "Cpu(s)"
        echo "========================================="
    } | tee $summary_file

    echo "Tests completed - full results in $log_file"
    echo "Summary saved to $summary_file"
}

# Main execution
main() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 <server_ip>"
        echo "Example: $0 10.0.0.10"
        exit 1
    fi

    local server_ip=$1

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root or with sudo"
        exit 1
    fi

    # Source backup script if exists
    if [ -f "./backup.sh" ]; then
        source ./backup.sh
        echo "Backing up system settings..."
        backup_settings
    else
        echo "Warning: backup.sh not found - proceeding without backup"
    fi

    echo "Installing prerequisites..."
    setup_tools

    echo "Optimizing network interface..."
    optimize_interface

    echo "Optimizing system settings..."
    window_size=$(optimize_system $server_ip)

    echo "Starting throughput tests..."
    run_test $server_ip $window_size

    # Restore settings if backup exists
    if [ -f "./backup.sh" ]; then
        echo "Restoring system settings..."
        restore_settings
    fi
}

main "$@"
