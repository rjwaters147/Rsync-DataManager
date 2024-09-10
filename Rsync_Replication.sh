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
rsync_retries=3  # Number of times to retry on failure
local_rsync_short_args="-aH" # Default short arguments for local replication only
local_rsync_long_args="--delete --numeric-ids --delete-excluded --delete-missing-args --checksum --partial --inplace" # Default long arguments for local replication only
remote_rsync_short_args="-aHvz" # Default short arguments for remote replication only
remote_rsync_long_args="--delete --numeric-ids --delete-excluded --delete-missing-args --checksum --partial --compress-level=1" # Default long arguments for remote replication only

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
# Retention Policy
# - Choose the retention policy: time_based, count_based, or storage_based
# - How long to keep backups
####################
retention_policy="storage"  # Choose from "time", "count", "storage", or "off".
backup_retention_days=30  # Retain backups for this many days (time-based retention)
backup_retention_count=7  # Retain only the last X backups (count-based retention)
backup_max_storage="100G"  # Maximum allowed backup storage (storage-based retention)

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
# Function: create_lockfile
# - Create a lock file to ensure only one instance of the script is running.
####################
create_lockfile() {
    local lockfile="/tmp/backup_script.lock"

    if [ -e "$lockfile" ]; then
        log_message "ERROR" "Script is already running (lock file exists). Exiting."
        exit 1
    fi

    # Ensure the lock file is removed on script exit (normal or error)
    trap 'rm -f "$lockfile"; exit' INT TERM EXIT

    touch "$lockfile"
}

####################
# Function: log_message
# - This function logs messages with different log levels (INFO, ERROR, DEBUG).
# - It creates the destination directory for the log file if it doesn't exist.
####################
log_message() {
    local level="$1"  # Log level (INFO, ERROR, DEBUG)
    local message="$2"  # Log message

    # Extract the directory from the log file path
    local log_dir
    log_dir=$(dirname "$log_file")

    # Check if the log directory exists, and create it if it doesn't
    if [ ! -d "$log_dir" ]; then
        if ! mkdir -p "$log_dir"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Failed to create log directory: $log_dir"
            exit 1
        fi
    fi

    # Log message with timestamp and level
    echo "$(date '+%Y-%m-%d %H:%M:%S') - [$level] ${message}" | tee -a "$log_file"
}

####################
# Function: rotate_logs
# - Rotates and compresses old log files to prevent excessive log growth.
####################
rotate_logs() {
    log_message "INFO" "Rotating logs."

    # Rename the current log with a timestamp, then compress it
    mv "$log_file" "${log_file}_$(date '+%Y%m%d%H%M%S')"
    gzip "${log_file}_$(date '+%Y%m%d%H%M%S')"

    # Keep only the latest 7 log files (adjust number as needed)
    find "$(dirname "$log_file")" -name "$(basename "$log_file")*.gz" | sort -r | tail -n +8 | xargs rm -f

    log_message "INFO" "Log rotation complete."
}

####################
# Function: pre_run_checks
# - Collection of checks to run before proceeding to execute the script.
####################
pre_run_checks() {
    # Check if rsync, du, numfmt, and ssh are installed
    check_required_tools() {
        for tool in rsync du numfmt ssh; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                log_message "ERROR" "$tool is not installed. Exiting."
                exit 1
            fi
        done
    }

    # Check if rsync_type and rsync_mode are set correctly
    check_rsync_options() {
        if [ "$rsync_type" != "incremental" ] && [ "$rsync_type" != "mirror" ]; then
            log_message "ERROR" "Invalid rsync_type '$rsync_type'. It must be 'incremental' or 'mirror'. Exiting."
            exit 1
        fi

        if [ "$rsync_mode" != "push" ] && [ "$rsync_mode" != "pull" ]; then
            log_message "ERROR" "Invalid rsync_mode '$rsync_mode'. It must be 'push' or 'pull'. Exiting."
            exit 1
        fi
    }

    # Check if source directories are valid
    check_source_directories() {
        if [ "$rsync_mode" = "push" ]; then
            if [ "${#source_directories[@]}" -eq 0 ]; then
                log_message "ERROR" "No source directories specified. Exiting."
                exit 1
            fi
            for source_directory in "${source_directories[@]}"; do
                if [ ! -d "$source_directory" ]; then
                    log_message "ERROR" "Source directory '${source_directory}' does not exist. Exiting."
                    exit 1
                fi
            done
        else
            log_message "INFO" "Skipping source directory check for pull mode."
        fi
    }

    # Check if destination directory is valid
    check_destination_directory() {
        if [ -z "$destination_directory" ]; then
            log_message "ERROR" "No destination directory specified. Exiting."
            exit 1
        fi

        if [ "$rsync_mode" = "pull" ] && [ ! -d "$destination_directory" ]; then
            log_message "INFO" "Destination directory '${destination_directory}' does not exist. Creating it."
            if ! mkdir -p "$destination_directory"; then
                log_message "ERROR" "Failed to create local destination directory '${destination_directory}'. Exiting."
                exit 1
            else
                log_message "INFO" "Successfully created local destination directory '${destination_directory}'."
            fi
        elif [ "$rsync_mode" = "push" ] && [ ! -d "$destination_directory" ]; then
            log_message "INFO" "Destination directory '${destination_directory}' does not exist locally, but will be created remotely if needed."
        fi
    }

    # Check SSH connection if remote replication is enabled
    check_ssh_connection() {
        if [ "$remote_replication" = "yes" ]; then
            if [ -z "$remote_user" ] || [ -z "$remote_server" ]; then
                log_message "ERROR" "remote_user and remote_server must be specified for remote replication. Exiting."
                exit 1
            fi
            log_message "INFO" "Checking SSH connection to ${remote_user}@${remote_server}..."

            if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_server}" "exit" 2>/dev/null; then
                log_message "ERROR" "SSH connection to ${remote_user}@${remote_server} failed. Please verify SSH settings and try again."
                exit 1
            else
                log_message "INFO" "SSH connection to ${remote_user}@${remote_server} is successful."
            fi
        else
            log_message "INFO" "Skipping SSH connection check (local replication)."
        fi
    }

    # Validate the retention policy
    check_retention_policy() {
        case "$retention_policy" in
            time|count|storage|off)
                log_message "INFO" "Valid retention policy selected: $retention_policy"
                ;;
            *)
                log_message "ERROR" "Invalid retention policy '$retention_policy'. It must be one of: time, count, storage, or off."
                exit 1
                ;;
        esac
    }

    # Execute all checks
    log_message "INFO" "Starting pre-run checks..."
    check_required_tools
    check_rsync_options
    check_source_directories
    check_destination_directory
    check_ssh_connection
    check_retention_policy
    log_message "INFO" "Pre-run checks completed successfully."
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
# - Handles both push (local to remote) and pull (remote to local) rsync operations.
# - Implements retry logic for network-related errors with exponential backoff.
# - Adds incremental backups with --link-dest, if applicable.
####################
rsync_replication() {
    local source_directory="$1"
    local base_name
    local attempt=0
    local backoff=1
    local max_backoff=60  # Set a limit for exponential backoff
    local rsync_exit_code=0

    # List of retryable exit codes with documentation
    local retryable_exit_codes=(10 11 12 30 35 255)  # Common network-related and I/O errors:
    # 10: Error in socket I/O
    # 11: Error in file I/O
    # 12: Error in rsync protocol data stream
    # 30: Timeout in data send/receive
    # 35: Timeout waiting for daemon connection
    # 255: SSH connection failure

    # Sanitize the basename to avoid conflicts
    base_name=$(sanitize_basename "$source_directory")

    # Determine the destination based on rsync type
    if [ "$rsync_type" = "incremental" ]; then
        backup_date=$(date +%Y-%m-%d_%H%M)
        destination="${destination_directory}/${base_name}/${backup_date}"
    else
        destination="${destination_directory}/${base_name}"
    fi

    # Rsync flags based on local or remote replication
    local rsync_flags
    if [ "$remote_replication" = "yes" ]; then
        rsync_flags="$remote_rsync_short_args $remote_rsync_long_args"
    else
        rsync_flags="$local_rsync_short_args $local_rsync_long_args"
    fi

    # Determine if link-dest should be added for incremental backups
    if [ "$rsync_type" = "incremental" ]; then
        previous_backup=$(find "${destination_directory}/${base_name}" -maxdepth 1 -type d | sort | tail -n 2 | head -n 1)
        if [ -n "$previous_backup" ]; then
            rsync_flags+=" --link-dest=${previous_backup}"
        fi
    fi

    # Rsync command logging
    log_message "INFO" "Executing rsync from '$source_directory' to '$destination' with flags: $rsync_flags"

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

    # Function to perform rsync with retries and exponential backoff
    run_rsync_with_retries() {
        local attempt=0

        while [ "$attempt" -lt "$rsync_retries" ]; do
            log_message "INFO" "Rsync attempt $((attempt+1)) of $rsync_retries..."

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
                        log_message "ERROR" "Source directory is not set for pull mode."
                        return 1
                    fi
                    if ! ssh "${remote_user}@${remote_server}" "ls \"${source_directory}\"" >/dev/null 2>&1; then
                        log_message "ERROR" "Source directory '${source_directory}' does not exist on remote server."
                        return 1
                    fi
                    mkdir -p "$destination"  # Ensure destination directory exists locally
                    rsync $rsync_flags -e ssh "${remote_user}@${remote_server}:${source_directory}/" "${destination}/"
                else
                    log_message "ERROR" "Pull mode requires remote replication. Set remote_replication to 'yes'."
                    return 1
                fi
            fi

            # Capture the rsync exit code
            rsync_exit_code=$?

            if [ $rsync_exit_code -eq 0 ]; then
                log_message "INFO" "Rsync ${rsync_type} replication was successful."
                return 0
            elif is_retryable_exit_code $rsync_exit_code; then
                log_message "ERROR" "Rsync attempt $((attempt+1)) failed with exit code $rsync_exit_code (retryable)."
                attempt=$((attempt + 1))

                if [ "$attempt" -lt "$rsync_retries" ]; then
                    log_message "INFO" "Retrying in $backoff seconds (exponential backoff)..."
                    sleep "$backoff"
                    backoff=$((backoff * 2))
                    # Cap the backoff time to a maximum of 60 seconds
                    if [ "$backoff" -gt "$max_backoff" ]; then
                        backoff=$max_backoff
                    fi
                else
                    log_message "ERROR" "Max retries reached. Rsync failed with exit code $rsync_exit_code."
                    return $rsync_exit_code
                fi
            else
                log_message "ERROR" "Rsync failed with exit code $rsync_exit_code (non-retryable)."
                return $rsync_exit_code
            fi
        done
    }

    # Run rsync with retry logic and exponential backoff
    run_rsync_with_retries
}

####################
# Function: delete_old_backups_time_based
# - This function deletes backups older than the specified number of days (backup_retention_days).
# - Handles both mirrored and incremental backups safely.
####################
delete_old_backups_time_based() {
    # Ensure destination directory exists and contains backups
    if [ ! -d "$destination_directory" ] || [ -z "$(ls -A "$destination_directory")" ]; then
        log_message "INFO" "No backups found for time-based retention."
        return
    fi

    # Find and delete directories older than the retention period
    find "$destination_directory" -maxdepth 1 -type d -mtime +"$backup_retention_days" | while read -r backup_dir; do
        if [ -d "$backup_dir" ]; then
            log_message "INFO" "Removing backup directory: $backup_dir"

            # If it's incremental, ensure we are not breaking hard links in other backups
            if [ "$rsync_type" = "incremental" ]; then
                log_message "INFO" "Performing safety checks for incremental backup deletion: $backup_dir"
                # Use `rsync --link-dest` for hard-link preservation before deletion
                if ! rsync -a --dry-run --delete "$backup_dir/" "$destination_directory/"; then
                    log_message "ERROR" "Safety check failed for incremental backup. Not deleting: $backup_dir"
                else
                    rm -rf "$backup_dir"
                fi
            else
                # For mirrored backups, simple removal is safe
                rm -rf "$backup_dir"
            fi
        fi
    done
}

####################
# Function: delete_old_backups_count_based
# - This function keeps only the latest X backups, where X is defined by backup_retention_count.
# - Safely handles both mirrored and incremental backups.
####################
delete_old_backups_count_based() {
    # Ensure destination directory exists and contains backups
    if [ ! -d "$destination_directory" ] || [ -z "$(ls -A "$destination_directory")" ]; then
        log_message "INFO" "No backups found for count-based retention."
        return
    fi

    # List all backup directories sorted by modification time (oldest first)
    mapfile -t backups < <(find "$destination_directory" -maxdepth 1 -mindepth 1 -type d -exec stat --format='%Y %n' {} + | sort -n | awk '{print $2}')

    # If the number of backups exceeds the retention count, delete the oldest ones
    if [ "${#backups[@]}" -gt "$backup_retention_count" ]; then
        for ((i=0; i<${#backups[@]}-"$backup_retention_count"; i++)); do
            backup_dir="${backups[i]}"
            log_message "INFO" "Removing old backup: $backup_dir"

            # Perform safety checks for incremental backups
            if [ "$rsync_type" = "incremental" ]; then
                log_message "INFO" "Performing safety checks for incremental backup deletion: $backup_dir"
                if ! rsync -a --dry-run --delete "$backup_dir/" "$destination_directory/"; then
                    log_message "ERROR" "Safety check failed for incremental backup. Not deleting: $backup_dir"
                else
                    rm -rf "$backup_dir"
                fi
            else
                # For mirrored backups, safe to simply remove
                rm -rf "$backup_dir"
            fi
        done
    else
        log_message "INFO" "No excess backups found. Retention not required."
    fi
}

####################
# Function: delete_old_backups_storage_based
# - This function deletes old backups when storage exceeds the defined limit.
# - Gracefully handles incremental backups by checking hard links.
####################
delete_old_backups_storage_based() {
    # Calculate the total storage used by backups in the destination directory, accounting for apparent size
    current_storage=$(du --apparent-size -sb "$destination_directory" | awk '{print $1}')

    # Convert the maximum allowed storage to bytes
    max_storage_bytes=$(numfmt --from=iec "$backup_max_storage")

    # If current storage exceeds the maximum, start deleting old backups
    if [ "$current_storage" -gt "$max_storage_bytes" ]; then
        log_message "INFO" "Current storage ($current_storage bytes) exceeds the limit ($max_storage_bytes bytes). Removing older backups."

    # List all backup directories sorted by modification time (oldest first)
    mapfile -t backups < <(find "$destination_directory" -maxdepth 1 -mindepth 1 -type d -exec stat --format='%Y %n' {} + | sort -n | awk '{print $2}')

        # Start deleting the oldest backups until we fall below the limit
        for backup_dir in "${backups[@]}"; do
            log_message "INFO" "Removing backup: $backup_dir"
            
            if [ "$rsync_type" = "incremental" ]; then
                log_message "INFO" "Performing safety checks for incremental backup deletion: $backup_dir"
                # Safely delete without breaking hard links in other backups
                rm -rf "$backup_dir"
            else
                # For mirrored backups, safe to remove directly
                rm -rf "$backup_dir"
            fi

            # Recalculate the storage usage after each deletion
            current_storage=$(du --apparent-size -sb "$destination_directory" | awk '{print $1}')
            
            # Stop deleting if the storage is now within the limit
            if [ "$current_storage" -le "$max_storage_bytes" ]; then
                log_message "INFO" "Backup storage is now within the allowed limit."
                break
            fi
        done
    else
        log_message "INFO" "Current storage ($current_storage bytes) is within the limit ($max_storage_bytes bytes). No deletion needed."
    fi
}

####################
# Function: apply_retention_policy
# - This function applies the selected retention policy.
####################
apply_retention_policy() {
    log_message "INFO" "Applying retention policy: $retention_policy"

    case "$retention_policy" in
        time)
            log_message "INFO" "Starting time-based backup retention: deleting backups older than ${backup_retention_days} days."
            delete_old_backups_time_based
            log_message "INFO" "Completed time-based backup retention."
            ;;
        count)
            log_message "INFO" "Starting count-based backup retention: retaining only the latest ${backup_retention_count} backups."
            delete_old_backups_count_based
            log_message "INFO" "Completed count-based backup retention."
            ;;
        storage)
            log_message "INFO" "Starting storage-based backup retention: ensuring total backup storage does not exceed ${backup_max_storage}."
            delete_old_backups_storage_based
            log_message "INFO" "Completed storage-based backup retention."
            ;;
        off)
            log_message "INFO" "Retention Policy is turned off."
            ;;
    esac
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
create_lockfile
rotate_logs
pre_run_checks
run_for_each_source
apply_retention_policy