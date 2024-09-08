#!/bin/bash
#set -x  # Uncomment for debugging (enables trace mode for debugging each command execution)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for Rsync to or from a remote server                                                                                           # #
# #   By rjwaters147 using ChatGPT Data Analyzer                                                                                            # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Configuration
####################

####################
# Source for replication (local if push, remote if pull)
# - These are the directories from where files will be synced.
# - Note: This should be the full path to the source directories.
# - In push mode: they're the local sources.
# - In pull mode: they're the remote sources.
####################
source_directories=("/path/to/source/directory1" "/path/to/source/directory2") # Can be one or multiple directories (e.g., "/mnt/data1" "/mnt/data2")

####################
# Destination for replication (local if pull, remote if push)
# - This is the directory to where files will be synced.
# - Note: This should be the full path to the destination directory.
# - In push mode: it's the remote destination.
# - In pull mode: it's the local destination.
####################
destination_directory="/path/to/destination/directory" # (e.g., "/mnt/backup")

####################
# Rsync replication variables
# - rsync_type: Determines whether the sync is incremental or full.
# - rsync_mode: Defines the direction of the sync: "push" (local to remote) or "pull" (remote to local).
####################
rsync_type="incremental" # Can be "incremental" or "mirror"
rsync_mode="push"  # Can be "push" or "pull"

####################
# Rsync flags (user-defined)
# - rsync_short_args: Short rsync arguments (e.g., "-a", "-v", "-z").
# - rsync_long_args: Long rsync arguments (e.g., "--delete", "--checksum").
# - Note: If rsync_type is set to incremental --link_dest will be added automatically
# - These flags will be applied based on the replication type.
####################
rsync_short_args="-avzH" # Suggested defaults
rsync_long_args="--delete --numeric-ids --delete-excluded --delete-missing-args --checksum --partial" # Suggested defaults
rsync_retries=3  # Number of times to retry on failure
rsync_retry_delay=5  # Delay in seconds between retries

####################
# Remote replication variables
# - remote_replication: Can be "yes" for remote replication or "no" for local replication.
# - remote_user: Username for remote server.
# - remote_server: Remote server address.
####################
remote_replication="no"  # Set to "yes" for remote replication, "no" for local replication
remote_user="remote_username" # Username for remote server (e.g., root)
remote_server="remote_server_address" # IP or hostname (e.g., 192.168.1.200)

####################
# Log file for debugging
# - Path where log messages will be saved.
####################
log_file="/path/to/logfile.log" # Path to log file (e.g., /var/log/rsync_replication.log)

####################
# Main Script
####################

# Used Basenames Map (Associative array to detect basename conflicts)
declare -A used_basenames

####################
# Funtction: log_message
# - This function is used to log messages with timestamps to the log file and console.
# - It creates the destination directory for the log file if it doesn't exist.
# - It appends to the log file if it already exists.
####################
log_message() {
    local message="$1"

    # Extract the directory from the log file path
    local log_dir
    log_dir=$(dirname "$log_file")

    # Check if the log directory exists, and create it if it doesn't
    if [ ! -d "$log_dir" ]; then
        if mkdir -p "$log_dir"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Failed to create log directory: $log_dir"
            exit 1
        fi
    fi

    # Log the message with a timestamp and append it to the log file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | tee -a "$log_file"
}

####################
# Function: pre_run_checks
# - Collection of checks to run before proceeding to execute the script
####################
pre_run_checks() {
    # Check if rsync is installed
    check_rsync_installed() {
        if ! command -v rsync >/dev/null 2>&1; then
            log_message "Error: Rsync is not installed. Exiting."
            exit 1
        fi
    }

    # Check if rsync_type and rsync_mode are set correctly
    check_rsync_options() {
        if ! check_valid_value "$rsync_type" "incremental" "mirror"; then
            log_message "Error: Invalid rsync_type '$rsync_type'. It must be 'incremental' or 'mirror'. Exiting."
            exit 1
        fi

        if ! check_valid_value "$rsync_mode" "push" "pull"; then
            log_message "Error: Invalid rsync_mode '$rsync_mode'. It must be 'push' or 'pull'. Exiting."
            exit 1
        fi
    }

    # Check if source directories are valid
    check_source_directories() {
        if [ "$rsync_mode" = "push" ]; then
            if [ "${#source_directories[@]}" -eq 0 ]; then
                log_message "Error: No source directories specified. Exiting."
                exit 1
            fi
            for source_directory in "${source_directories[@]}"; do
                if [ ! -d "$source_directory" ]; then
                    log_message "Error: Source directory '${source_directory}' does not exist. Exiting."
                    exit 1
                fi
            done
        else
            log_message "Skipping source directory check for pull mode."
        fi
    }

    # Check if destination directory is valid
    check_destination_directory() {
        if [ -z "$destination_directory" ]; then
            log_message "Error: No destination directory specified. Exiting."
            exit 1
        fi

        if [ "$rsync_mode" = "pull" ] && [ ! -d "$destination_directory" ]; then
            log_message "Destination directory '${destination_directory}' does not exist. Creating it."
            if ! mkdir -p "$destination_directory"; then
                log_message "Error: Failed to create local destination directory '${destination_directory}'. Exiting."
                exit 1
            else
                log_message "Successfully created local destination directory '${destination_directory}'."
            fi
        elif [ "$rsync_mode" = "push" ] && [ ! -d "$destination_directory" ]; then
            log_message "Destination directory '${destination_directory}' does not exist locally, but will be created remotely if needed."
        fi
    }

    # Check SSH connection if remote replication is enabled
    check_ssh_connection() {
        if [ "$remote_replication" = "yes" ]; then
            if [ -z "$remote_user" ] || [ -z "$remote_server" ]; then
                log_message "Error: remote_user and remote_server must be specified for remote replication. Exiting."
                exit 1
            fi
            log_message "Checking SSH connection to ${remote_user}@${remote_server}..."
            if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_server}" "exit" 2>/dev/null; then
                log_message "Error: SSH connection to ${remote_user}@${remote_server} failed. Exiting."
                exit 1
            else
                log_message "SSH connection to ${remote_user}@${remote_server} is successful."
            fi
        else
            log_message "Skipping SSH connection check (local replication)."
        fi
    }

    # Execute all checks
    log_message "Starting pre-run checks..."
    check_rsync_installed
    check_rsync_options
    check_source_directories
    check_destination_directory
    check_ssh_connection
    log_message "Pre-run checks completed successfully."
}

####################
# Function: sanitize_basename
# - This function takes the source directory and checks if a basename conflict exists.
# - If a conflict exists, it appends the immediate parent directory to make the basename unique.
####################
sanitize_basename() {
    local source_directory="$1"
    local base_name
    base_name=$(basename "$source_directory")

    # Check if the basename has already been used
    if [[ -n "${used_basenames[$base_name]}" ]]; then
        # Conflict detected, append the immediate parent directory to the basename
        local parent_dir
        parent_dir=$(basename "$(dirname "$source_directory")")
        base_name="${parent_dir}_${base_name}"
    fi

    # Mark this basename as used
    used_basenames["$base_name"]=1

    echo "$base_name"
}

####################
# Function: rsync_replication
# - This function handles both push (local to remote) and pull (remote to local) rsync operations.
# - It implements retry logic in case of rsync failure, especially for network-related issues.
# - The function retries rsync up to a specified number of times if it fails due to specific transient errors.
####################
rsync_replication() {
    local source_directory="$1"
    local base_name
    local attempt=0
    local rsync_exit_code=0

    # List of retryable exit codes (common network-related and I/O errors)
    local retryable_exit_codes=(10 11 12 30 35 255)  # Socket I/O, File I/O, Protocol errors, Timeouts, SSH failure

    # Sanitize the basename to avoid conflicts
    base_name=$(sanitize_basename "$source_directory")

    # Determine the destination based on rsync type
    if [ "$rsync_type" = "incremental" ]; then
        backup_date=$(date +%Y-%m-%d_%H%M)
        destination="${destination_directory}/${base_name}/${backup_date}"
    else
        destination="${destination_directory}/${base_name}"
    fi

    # Rsync flags to speed up remote replication
    local rsync_flags="$rsync_short_args $rsync_long_args"

    # Rsync command logging
    log_message "Executing rsync from '$source_directory' to '$destination' with flags: $rsync_flags"

    # Function to check if the rsync exit code is retryable
    is_retryable_exit_code() {
        local exit_code=$1
        for code in "${retryable_exit_codes[@]}"; do
            if [ "$exit_code" -eq "$code" ]; then
                return 0
            fi
        done
        return 1
    }

    # Function to perform rsync with retries
    run_rsync_with_retries() {
        local attempt=0

        while [ "$attempt" -lt "$rsync_retries" ]; do
            log_message "Rsync attempt $((attempt+1)) of $rsync_retries..."

            # Rsync for push mode (local to remote)
            if [ "$rsync_mode" = "push" ]; then
                if [ "$remote_replication" = "yes" ]; then
                    ssh "${remote_user}@${remote_server}" "mkdir -p \"${destination}\""
                    rsync $rsync_flags -e ssh "${source_directory}/" "${remote_user}@${remote_server}:${destination}/"
                else
                    mkdir -p "$destination"  # Ensure destination directory exists locally
                    rsync $rsync_flags "${source_directory}/" "${destination}/"
                fi
            # Rsync for pull mode (remote to local)
            elif [ "$rsync_mode" = "pull" ]; then
                if [ "$remote_replication" = "yes" ]; then
                    if [ -z "$source_directory" ]; then
                        log_message "Error: source directory is not set for pull mode."
                        return 1
                    fi
                    if ! ssh "${remote_user}@${remote_server}" "ls \"${source_directory}\"" >/dev/null 2>&1; then
                        log_message "Error: Source directory '${source_directory}' does not exist on remote server."
                        return 1
                    fi
                    mkdir -p "$destination"  # Ensure destination directory exists locally
                    rsync $rsync_flags -e ssh "${remote_user}@${remote_server}:${source_directory}/" "${destination}/"
                else
                    log_message "Error: Pull mode requires remote replication. Set remote_replication to 'yes'."
                    return 1
                fi
            fi

            # Capture the rsync exit code
            rsync_exit_code=$?

            if [ $rsync_exit_code -eq 0 ]; then
                log_message "Rsync ${rsync_type} replication was successful."
                return 0
            elif is_retryable_exit_code $rsync_exit_code; then
                log_message "Rsync attempt $((attempt+1)) failed with exit code $rsync_exit_code (retryable)."
                attempt=$((attempt + 1))

                if [ "$attempt" -lt "$rsync_retries" ]; then
                    log_message "Retrying in $rsync_retry_delay seconds..."
                    sleep "$rsync_retry_delay"
                else
                    log_message "Max retries reached. Rsync failed with exit code $rsync_exit_code."
                    return $rsync_exit_code
                fi
            else
                log_message "Rsync failed with exit code $rsync_exit_code (non-retryable)."
                return $rsync_exit_code
            fi
        done
    }

    # Run rsync with retry logic
    run_rsync_with_retries
}

####################
# Function: run_for_each_source
# - This function loops through each source directory and performs rsync replication.
####################
run_for_each_source() {
    # Loop through each source directory and perform rsync
    for source_directory in "${source_directories[@]}"; do
        log_message "Starting replication for source directory: ${source_directory}"
        rsync_replication "$source_directory"
    done
    log_message "Replication completed for all source directories."
}

####################
# Main Script Execution
####################
pre_run_checks
run_for_each_source