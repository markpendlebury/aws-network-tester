#!/bin/bash

BACKUP_FILE="./network-settings.backup"

# List of sysctl parameters we want to backup
SYSCTL_PARAMS=(
    "net.core.rmem_max"
    "net.core.wmem_max"
    "net.core.rmem_default"
    "net.core.wmem_default"
    "net.ipv4.tcp_rmem"
    "net.ipv4.tcp_wmem"
    "net.ipv4.tcp_window_scaling"
    "net.ipv4.tcp_max_syn_backlog"
    "net.core.netdev_max_backlog"
    "net.ipv4.tcp_no_metrics_save"
    "net.ipv4.tcp_moderate_rcvbuf"
    "net.ipv4.tcp_congestion_control"
    "net.ipv4.tcp_mtu_probing"
    "net.ipv4.tcp_slow_start_after_idle"
)

backup_settings() {
    local backup_file="$BACKUP_FILE"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local temp_file="${backup_file}_${timestamp}"

    echo "Backing up current network settings..."

    # Create backup with timestamp in comments
    echo "# Network settings backup created on $(date)" >"$temp_file"
    echo "# System: $(uname -a)" >>"$temp_file"
    echo "" >>"$temp_file"

    # Backup each parameter
    for param in "${SYSCTL_PARAMS[@]}"; do
        if sysctl -a 2>/dev/null | grep -q "^$param\s*="; then
            value=$(sysctl -n "$param" 2>/dev/null)
            echo "${param}=${value}" >>"$temp_file"
        else
            echo "# ${param} not found" >>"$temp_file"
        fi
    done

    # Atomic move to final backup file
    mv "$temp_file" "$backup_file"

    if [ $? -eq 0 ]; then
        echo "Backup completed successfully to $backup_file"
        echo "Backup contains $(grep -c "^net\." "$backup_file") parameters"
    else
        echo "Error creating backup"
        return 1
    fi
}

restore_settings() {
    local backup_file="$BACKUP_FILE"

    if [ ! -f "$backup_file" ]; then
        echo "Error: Backup file $backup_file not found"
        return 1
    fi

    echo "Restoring network settings from $backup_file..."

    # Create a temporary file for logging
    local log_file=$(mktemp)

    # Read and apply each setting
    while IFS='=' read -r param value; do
        # Skip comments and empty lines
        [[ $param =~ ^#.*$ ]] && continue
        [[ -z $param ]] && continue

        # Apply setting
        if echo "$param" | grep -q "^net\."; then
            echo "Restoring $param to $value"
            if sudo sysctl -w "$param=$value" >>"$log_file" 2>&1; then
                echo "✓ Successfully restored $param"
            else
                echo "✗ Failed to restore $param"
            fi
        fi
    done <"$backup_file"

    # Check for any errors in the log
    if grep -q "error" "$log_file"; then
        echo "Some errors occurred during restoration. Check $log_file for details"
    else
        echo "All settings restored successfully"
        rm "$log_file"
    fi
}
