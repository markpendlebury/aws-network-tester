#!/bin/bash

# Test Configuration
BANDWIDTH_GBPS=100
PARALLEL_STREAMS=32
TEST_DURATION=120
BUFFER_SIZE="1M"

# TCP Buffer Size
RMEME_MAX=16777216
WMEM_MAX=16777216
TCP_RMEM="4096 87380 16777216"
TCP_WMEM="4096 87380 16777216"

# Install prerequisites
setup_tools() {

    required_packages=(iperf3)

    for package in "${required_packages[@]}"; do
        if ! command -v $package &>/dev/null; then
            echo "$package could not be found, installing..."
            sudo yum install $package -y
        fi
    done
}

# Function to measure RTT
measure_rtt() {
    local target_ip=$1
    local samples=5

    echo "Measuring RTT to $target_ip..."
    # Get average RTT in milliseconds using a more reliable method
    rtt=$(ping -c $samples $target_ip |
        awk -F '/' 'END {print $5}')

    # Check if rtt is empty or zero, set default if needed
    if [[ -z "$rtt" ]] || [[ "$rtt" == "0" ]]; then
        rtt="1.0"
    fi

    echo "Average RTT: ${rtt}ms"
    echo

    # Convert to seconds
    echo "scale=6; $rtt/1000" | bc
}

# Calculate optimal window size
calculate_window() {
    local bandwidth_gbps=$1 # Bandwidth in Gbps
    local rtt_sec=$2        # RTT in seconds

    echo "Calculating optimal TCP window size:"
    echo "- Bandwidth: $bandwidth_gbps Gbps"
    echo "- RTT: $(echo "scale=3; $rtt_sec * 1000" | bc) ms"

    # Calculate window size in bytes
    # Formula: bandwidth (bits/sec) × RTT (sec) / 8 (to convert to bytes)
    local window_size=$(echo "scale=0; ($bandwidth_gbps * 1000 * 1000 * 1000 * $rtt_sec) / 8" | bc)

    echo "- Calculated window size: $window_size bytes ($(echo "scale=2; $window_size/1024/1024" | bc) MB)"
    echo

    # Round up to nearest power of 2 for better performance
    local power=1
    while [ $power -lt $window_size ]; do
        power=$((power * 2))
    done

    echo "- Rounded window size: $power bytes ($(echo "scale=2; $power/1024/1024" | bc) MB)"
    echo

    echo $power
}

# Apply TCP window settings
apply_settings() {

    echo "Applying TCP window settings..."

    # Set minimum, default
    local window_size_min=4096
    local window_size_default=87380
    local window_size_max=$1

    # Apply settings
    sudo sysctl -w net.core.rmem_max=$window_size_max
    sudo sysctl -w net.core.wmem_max=$window_size_max
    sudo sysctl -w net.ipv4.tcp_rmem="$window_size_min $window_size_default $window_size_max"
    sudo sysctl -w net.ipv4.tcp_wmem="$window_size_min $window_size_default $window_size_max"
    sudo sysctl -w net.ipv4.tcp_window_scaling=1

    echo "Settings applied successfully!"
    echo

    # Verify settings
    echo "Current TCP window settings:"
    sysctl net.core.rmem_max
    sysctl net.core.wmem_max
    sysctl net.ipv4.tcp_rmem
    sysctl net.ipv4.tcp_wmem
    sysctl net.ipv4.tcp_window_scaling
}

# Optimize system settings
optimize_system() {
    local target_ip=$1
    local rtt_sec=$(measure_rtt $target_ip)
    local window_size=$(calculate_window $BANDWIDTH_GBPS $rtt_sec)
    apply_settings $window_size
    echo $window_size
}

# Main execution

run_test() {
    local server_ip=$1
    local window_size=$2
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="iperf_test_${timestamp}.log"
    local summary_file="iperf_summary_${timestamp}.txt"

    echo "Starting tests - results will be logged to $log_file"

    {
        echo "=== TCP Tests ==="
        echo "Running TCP test with $PARALLEL_STREAMS parallel streams..."

        # Download test (reverse mode)
        echo "Testing Download Speed..."
        download_speed=$(iperf3 -c $server_ip \
            -P $PARALLEL_STREAMS \
            -t $TEST_DURATION \
            -l $BUFFER_SIZE \
            -w $window_size \
            --tcp-window-size $window_size \
            -R | grep "sender" | tail -n1 | awk '{print $7}')

        sleep 2

        # Upload test
        echo "Testing Upload Speed..."
        upload_speed=$(iperf3 -c $server_ip \
            -P $PARALLEL_STREAMS \
            -t $TEST_DURATION \
            -l $BUFFER_SIZE \
            -w $window_size \
            --tcp-window-size $window_size | grep "sender" | tail -n1 | awk '{print $7}')

    } 2>&1 | tee $log_file

    # Create summary
    {
        echo "========================================="
        echo "         IPERF3 TEST SUMMARY"
        echo "========================================="
        echo "Test completed at: $(date)"
        echo "Server IP: $server_ip"
        echo "-----------------------------------------"
        echo "Maximum Download Speed: $download_speed Gbits/sec"
        echo "Maximum Upload Speed: $upload_speed Gbits/sec"
        echo "========================================="
    } | tee $summary_file

    echo "Tests completed - full results in $log_file"
    echo "Summary saved to $summary_file"
}

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

    # Source backup script
    if [ -f "./backup.sh" ]; then
        source ./backup.sh
        echo "Backing up system settings..."
        backup_settings
    else
        echo "Warning: backup.sh not found - proceeding without backup"
    fi

    echo "Installing prerequisites..."
    setup_tools

    echo "Optimizing system settings..."
    optimize_system $server_ip

    echo "Starting throughput tests..."
    run_test $server_ip

    # Restore settings if backup script exists
    if [ -f "./backup.sh" ]; then
        echo "Restoring system settings..."
        restore_settings
    fi

}

main "$@"
