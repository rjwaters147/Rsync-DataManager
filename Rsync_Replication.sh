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
# - rsync_shortargs: Short rsync arguments (e.g., "-a", "-v", "-z").
# - rsync_longargs: Long rsync arguments (e.g., "--delete", "--checksum").
# - These flags will be applied based on the replication type.
####################
rsync_shortargs="-azv" # Default: archive mode, compress, verbose
rsync_longargs="--delete" # Default: delete files on destination if not present on source

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
# - Ensures that rsync is installed and that the source and destination directories exist.
# - Checks SSH connection if remote replication is enabled.
####################
pre_run_checks() {
    # Check if rsync is installed
    check_rsync_installed() {
        if [ "$rsync_mode" = "push" ] && ! command -v rsync >/dev/null 2>&1; then
            log_message "Rsync is not installed. Exiting."
            exit 1
        fi
    }

    # Check if each source directory exists (for push only)
    check_source_directories() {
        if [ "$rsync_mode" = "push" ]; then
            for source_directory in "${source_directories[@]}"; do
                if [ ! -d "$source_directory" ]; then
                    log_message "Source directory ${source_directory} does not exist. Exiting."
                    exit 1
                fi
            done
        else
            log_message "Skipping source directory check for pull mode."
        fi
    }

    # Check if the destination directory exists (for push or pull)
    check_destination_directory() {
        if [ ! -d "$destination_directory" ]; then
            log_message "Destination directory ${destination_directory} does not exist locally. Creating it."
            if ! mkdir -p "$destination_directory"; then
                log_message "Failed to create local destination directory ${destination_directory}. Exiting."
                exit 1
            else
                log_message "Successfully created local destination directory ${destination_directory}."
            fi
        fi
    }

    # Check SSH connection if needed (for remote replication)
    check_ssh_connection() {
        if [ "$remote_replication" = "yes" ]; then
            log_message "Checking SSH connection to ${remote_user}@${remote_server}..."
            if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_server}" "exit" 2>/dev/null; then
                log_message "SSH connection to ${remote_user}@${remote_server} failed. Exiting."
                exit 1
            else
                log_message "SSH connection to ${remote_user}@${remote_server} is successful."
            fi
        else
            log_message "Skipping SSH connection check (local replication)."
        fi
    }

    # Execute all checks
    check_rsync_installed
    check_source_directories
    check_destination_directory
    check_ssh_connection
}

####################
# Function: get_previous_backup
# - This function sets the previous_backup variable to the most recent backup directory.
# - If remote replication is disabled, it performs local backup lookup.
####################
get_previous_backup() {
    if [ "$rsync_type" = "incremental" ]; then
        if [ "$remote_replication" = "yes" ]; then
            if [ "$rsync_mode" = "push" ]; then
                previous_backup=$(ssh "${remote_user}@${remote_server}" "ls \"${destination_directory}\" | sort -r | head -n 2 | tail -n 1")
            else
                previous_backup=$(find "${destination_directory}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -r | head -n 1)
            fi
        else
            # Local-only backup
            previous_backup=$(find "${destination_directory}" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort -r | head -n 1)
        fi
    fi
}

####################
# Function: rsync_replication
# - This function handles both push (local to remote) and pull (remote to local) rsync operations.
# - It calls pre_run_checks to ensure that all necessary checks are performed before running rsync.
####################
rsync_replication() {
    local source_directory="$1"

    get_previous_backup

    # Determine the destination based on rsync type
    if [ "$rsync_type" = "incremental" ]; then
        backup_date=$(date +%Y-%m-%d_%H%M)
        destination="${destination_directory}/${backup_date}"
    else
        destination="${destination_directory}"
    fi

    # Determine link-dest option for incremental backups
    local link_dest_option=""
    if [ -n "$previous_backup" ]; then
        link_dest_path="${destination_directory}/${previous_backup}"
        if [ "$rsync_type" = "incremental" ]; then
            if [ -d "$link_dest_path" ]; then
                link_dest_option="--link-dest=${link_dest_path}"
            else
                log_message "Warning: --link-dest arg does not exist: ${link_dest_path}, skipping link-dest option."
            fi
        fi
    fi

    # Rsync flags to speed up remote replication
    local rsync_flags="$rsync_shortargs $rsync_longargs $link_dest_option"
    if [ "$remote_replication" = "yes" ]; then
        rsync_flags="$rsync_flags --partial --checksum"
    fi

    # Rsync for push mode (local to remote)
    if [ "$rsync_mode" = "push" ]; then
        if [ "$remote_replication" = "yes" ]; then
            ssh "${remote_user}@${remote_server}" "mkdir -p \"${destination}\""
            if rsync $rsync_flags -e ssh "${source_directory}/" "${remote_user}@${remote_server}:${destination}/"; then
                log_message "Rsync ${rsync_type} push replication was successful to remote destination: ${remote_user}@${remote_server}:${destination}"
            else
                log_message "Rsync push replication failed to remote destination: ${remote_user}@${remote_server}:${destination}"
                return 1
            fi
        else
            # Local-only replication
            if rsync $rsync_flags "${source_directory}/" "${destination}/"; then
                log_message "Rsync ${rsync_type} local replication was successful to local destination: ${destination}"
            else
                log_message "Rsync local replication failed to local destination: ${destination}"
                return 1
            fi
        fi

    # Rsync for pull mode (remote to local)
    elif [ "$rsync_mode" = "pull" ]; then
        if [ "$remote_replication" = "yes" ]; then
            if [ -z "$source_directory" ]; then
                log_message "Error: source directory is not set for pull mode."
                return 1
            fi
            ssh "${remote_user}@${remote_server}" "ls \"${source_directory}\""
            if rsync $rsync_flags -e ssh "${remote_user}@${remote_server}:${source_directory}/" "${destination}/"; then
                log_message "Rsync ${rsync_type} pull replication was successful from remote source: ${remote_user}@${remote_server}:${source_directory} to local destination: ${destination}"
            else
                log_message "Rsync pull replication failed from remote source: ${remote_user}@${remote_server}:${source_directory} to local destination: ${destination}"
                return 1
            fi
        else
            log_message "Error: Pull mode requires remote replication. Set remote_replication to 'yes'."
            return 1
        fi
    fi
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