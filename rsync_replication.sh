#!/bin/bash
#set -x  # Uncomment for debugging (trace mode)
set -euo pipefail  # Ensures the script exits on unhandled errors and no unset vars are used

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for Rsync to or from a remote server                                                                                           # #
# #   This script is intended to be run alongside rsync_config.sh                                                                           # #
# #   Contains advanced replication logic, logging, retries, atomic backups, and retention                                                  # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Source the configuration file
# - The configuration file must define variables like source_directories, destination_directory, rsync_type, rsync_mode, etc.
# - Make sure rsync_config.sh is in the same directory or adjust the path as needed.
####################
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/rsync_config.sh"

####################
# Function: log_message
# - Logs messages at various levels to syslog, respecting a user-defined LOG_LEVEL.
# - LOG_LEVEL is set in rsync_config.sh (DEBUG, INFO, WARN, ERROR).
####################
log_message() {
    local level="$1"
    local message="$2"

    local syslog_priority="user.notice"
    case "$level" in
        DEBUG) syslog_priority="user.debug" ;;
        INFO)  syslog_priority="user.info"  ;;
        WARN)  syslog_priority="user.warn"  ;;
        ERROR) syslog_priority="user.err"   ;;
        *)     syslog_priority="user.notice" ;;
    esac

    declare -A LEVEL_ORDER=( ["DEBUG"]=10 ["INFO"]=20 ["WARN"]=30 ["ERROR"]=40 )

    : "${LOG_LEVEL:=INFO}"  # fallback if not set

    local message_level_num="${LEVEL_ORDER[$level]:-20}"
    local current_level_num="${LEVEL_ORDER[$LOG_LEVEL]:-20}"

    if (( message_level_num >= current_level_num )); then
        logger -t "rsync_replication" -p "$syslog_priority" "[${level}] ${message}"
    fi
}

####################
# Function: validate_path
# - Checks a path for suspicious characters or patterns
# - If invalid chars found, logs an error and exits.
####################
validate_path() {
    local path="$1"

    if [[ "$path" =~ [\"\';\|\(\)\&] ]]; then
        log_message "ERROR" "Path '$path' contains invalid shell characters. Exiting."
        exit 1
    fi
    if [[ "$path" =~ [[:space:]] ]]; then
        log_message "WARN" "Path '$path' contains spaces. Ensure quoting is correct."
    fi
    if [[ -z "$path" ]]; then
        log_message "ERROR" "Path is empty. Exiting."
        exit 1
    fi
}

####################
# Function: pre_run_checks
# - Validates environment before proceeding:
#   1) Checks if required tools (rsync, ssh, etc.) are installed.
#   2) Ensures rsync_type and rsync_mode are valid.
#   3) Verifies that source and destination directories exist (depending on mode).
#   4) Checks SSH connectivity if remote replication is enabled.
#   5) Validates the retention policy configuration.
####################
pre_run_checks() {

    ####################
    # Check required tools
    ####################
    check_required_tools() {
        for tool in rsync du numfmt ssh logger flock; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                log_message "ERROR" "Required tool '$tool' is not installed. Exiting."
                exit 1
            fi
        done
    }

    ####################
    # Check rsync options
    ####################
    check_rsync_options() {
        if [[ "$rsync_type" != "incremental" && "$rsync_type" != "mirror" ]]; then
            log_message "ERROR" "Invalid rsync_type '$rsync_type'. Must be 'incremental' or 'mirror'. Exiting."
            exit 1
        fi
        if [[ "$rsync_mode" != "push" && "$rsync_mode" != "pull" ]]; then
            log_message "ERROR" "Invalid rsync_mode '$rsync_mode'. Must be 'push' or 'pull'. Exiting."
            exit 1
        fi
    }

    ####################
    # Check source directories
    ####################
    check_source_directories() {
        if [ "${#source_directories[@]}" -eq 0 ]; then
            log_message "ERROR" "No source directories specified. Exiting."
            exit 1
        fi
        # If push mode, check local existence of sources
        if [ "$rsync_mode" = "push" ]; then
            for src in "${source_directories[@]}"; do
                validate_path "$src"
                if [ ! -d "$src" ]; then
                    log_message "ERROR" "Source directory '$src' does not exist. Exiting."
                    exit 1
                fi
            done
        else
            log_message "INFO" "Pull mode: skipping local source directory checks."
        fi
    }

    ####################
    # Check destination directory
    ####################
    check_destination_directory() {
        if [ -z "$destination_directory" ]; then
            log_message "ERROR" "No destination directory specified. Exiting."
            exit 1
        fi
        validate_path "$destination_directory"
        if [ "$rsync_mode" = "pull" ] && [ ! -d "$destination_directory" ]; then
            log_message "INFO" "Destination directory '$destination_directory' does not exist locally. Creating it."
            mkdir -p "$destination_directory" || {
                log_message "ERROR" "Failed to create local destination directory '$destination_directory'. Exiting."
                exit 1
            }
        fi
    }

    ####################
    # Check SSH connection if remote_replication = yes
    ####################
    check_ssh_connection() {
        if [ "$remote_replication" = "yes" ]; then
            if [ -z "$remote_user" ] || [ -z "$remote_server" ]; then
                log_message "ERROR" "remote_user or remote_server not specified for remote replication. Exiting."
                exit 1
            fi
            log_message "INFO" "Checking SSH connection to ${remote_user}@${remote_server}..."
            if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_user}@${remote_server}" exit 2>/dev/null; then
                log_message "ERROR" "SSH connection to ${remote_user}@${remote_server} failed. Exiting."
                exit 1
            else
                log_message "INFO" "SSH connection to ${remote_user}@${remote_server} successful."
            fi
        else
            log_message "INFO" "Local replication: skipping SSH connection check."
        fi
    }

    ####################
    # Check retention policy
    ####################
    check_retention_policy() {
        case "$retention_policy" in
            time|count|off)
                log_message "INFO" "Valid retention policy selected: $retention_policy."
                ;;
            *)
                log_message "ERROR" "Invalid retention policy '$retention_policy'. Must be 'time', 'count', or 'off'. Exiting."
                exit 1
                ;;
        esac
    }

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
# Basename conflict handling
# - Ensures each source directory produces a unique name in the backup destination.
# - If conflicts occur, appends the parent directory to the base name.
####################
declare -A used_basenames
sanitize_basename() {
    local source_directory="$1"
    local base_name
    base_name=$(basename "$source_directory")

    # Instead of: if [[ -n "${used_basenames[$base_name]}" ]]; then
    if [[ "${used_basenames[$base_name]+exists}" == "exists" ]]; then
        local parent_dir
        parent_dir=$(basename "$(dirname "$source_directory")")
        base_name="${parent_dir}_${base_name}"
    fi

    used_basenames["$base_name"]=1
    echo "$base_name"
}

####################
# Function: check_disk_space_local
# - Verifies adequate free space before backup if destination is local.
# - Uses du and df to compare the size of source vs available space.
####################
check_disk_space_local() {
    local source_path="$1"
    local destination_path="$2"

    # If the operation is local (remote_replication=no) or pull mode, we can reliably check disk usage
    if [ "$remote_replication" = "no" ] || [ "$rsync_mode" = "pull" ]; then
        if [ -d "$source_path" ] && [ -d "$destination_path" ]; then
            local required
            local available
            required=$(du -s "$source_path" | cut -f1)  # in KB
            available=$(df --output=avail -k "$destination_path" | tail -n 1)
            if [ "$available" -lt "$required" ]; then
                log_message "ERROR" "Insufficient space to back up '$source_path' into '$destination_path'. Exiting."
                exit 1
            fi
        fi
    fi
}

####################
# Function: add_inprogress_dir
# - Appends the directory path to partial_inprogress_list_file.
# - Uses flock for concurrency safety (optional).
####################
add_inprogress_dir() {
    local dir="$1"
    {
        flock -x 200
        echo "$dir" >> "$partial_inprogress_list_file"
    } 200>>"$partial_inprogress_list_file"
}

####################
# Function: remove_inprogress_dir
# - Removes the specified directory from partial_inprogress_list_file.
# - Also uses flock to avoid race conditions.
####################
remove_inprogress_dir() {
    local dir="$1"
    if [ -f "$partial_inprogress_list_file" ]; then
        {
            flock -x 200
            sed -i "\|^${dir}\$|d" "$partial_inprogress_list_file"
        } 200>>"$partial_inprogress_list_file"
    fi
}

####################
# Cleanup leftover .inprogress directories on interrupt
# - Reads partial_inprogress_list_file, removes directories, clears the file.
####################
cleanup_function() {
    log_message "WARN" "Caught interrupt signal. Cleaning up leftover .inprogress directories..."

    if [ -f "$partial_inprogress_list_file" ]; then
        {
            flock -x 200
            while IFS= read -r dir; do
                if [ -n "$dir" ] && [ -d "$dir" ]; then
                    log_message "INFO" "Removing partial directory: $dir"
                    rm -rf "$dir"
                fi
            done < "$partial_inprogress_list_file"

            # Clear the file so leftover entries aren't repeated
            : > "$partial_inprogress_list_file"
        } 200>>"$partial_inprogress_list_file"
    fi

    exit 1
}
trap 'cleanup_function' INT TERM

####################
# Function: rsync_replication
# - Handles push/pull logic, incremental vs mirror.
# - Implements retry logic and atomic backups (.inprogress → final).
####################
rsync_replication() {
    local source_directory="$1"
    local base_name
    local backup_date
    local destination
    local rsync_exit_code=0

    base_name=$(sanitize_basename "$source_directory")

    if [ "$rsync_type" = "incremental" ]; then
        backup_date=$(date +%Y-%m-%d_%H%M)
        destination="${destination_directory}/${base_name}/${backup_date}"
    else
        destination="${destination_directory}/${base_name}"
    fi

    local rsync_flags
    if [ "$remote_replication" = "yes" ]; then
        rsync_flags="$remote_rsync_short_args $remote_rsync_long_args"
    else
        rsync_flags="$local_rsync_short_args $local_rsync_long_args"
    fi

    if [ -d "${destination_directory}/${base_name}" ]; then
        previous_backup=$(find "${destination_directory}/${base_name}" -maxdepth 1 -type d | sort | tail -n 1)
        if [ -n "$previous_backup" ] && [ "$previous_backup" != "${destination_directory}/${base_name}" ]; then
            rsync_flags+=" --link-dest=${previous_backup}"
        fi
    else
        log_message "INFO" "No previous backups found (destination directory does not exist yet). Skipping --link-dest."
    fi

    check_disk_space_local "$source_directory" "$(dirname "$destination")"

    log_message "INFO" "Executing rsync from '$source_directory' to '$destination' with flags: $rsync_flags"

    local retryable_exit_codes=(10 11 12 30 35 255)
    local attempt=0
    local backoff=1
    local max_backoff=60

    is_retryable_exit_code() {
        local code="$1"
        for ec in "${retryable_exit_codes[@]}"; do
            if [ "$code" -eq "$ec" ]; then
                return 0
            fi
        done
        return 1
    }

    run_rsync_with_retries() {
        while [ "$attempt" -lt "$rsync_retries" ]; do
            log_message "INFO" "Rsync attempt $((attempt+1)) of $rsync_retries..."

            if [ "$rsync_mode" = "push" ]; then
                if [ "$remote_replication" = "yes" ]; then
                    ssh "${remote_user}@${remote_server}" "mkdir -p \"${destination}\""
                    rsync $rsync_flags -e ssh "${source_directory}/" "${remote_user}@${remote_server}:${destination}/"
                    rsync_exit_code=$?
                else
                    mkdir -p "$(dirname "$destination")"
                    local temp_dest="${destination}.inprogress"

                    add_inprogress_dir "$temp_dest"

                    mkdir -p "$temp_dest"
                    rsync $rsync_flags "${source_directory}/" "${temp_dest}/"
                    rsync_exit_code=$?

                    if [ $rsync_exit_code -eq 0 ]; then
                        mv "$temp_dest" "$destination"
                        remove_inprogress_dir "$temp_dest"
                    else
                        rm -rf "$temp_dest"
                        remove_inprogress_dir "$temp_dest"
                    fi
                fi
            else
                if [ "$remote_replication" = "yes" ]; then
                    if ! ssh "${remote_user}@${remote_server}" "ls \"${source_directory}\"" >/dev/null 2>&1; then
                        log_message "ERROR" "Source directory '$source_directory' does not exist on remote server."
                        return 1
                    fi
                    mkdir -p "$(dirname "$destination")"
                    local temp_dest="${destination}.inprogress"

                    add_inprogress_dir "$temp_dest"

                    mkdir -p "$temp_dest"
                    rsync $rsync_flags -e ssh "${remote_user}@${remote_server}:${source_directory}/" "${temp_dest}/"
                    rsync_exit_code=$?

                    if [ $rsync_exit_code -eq 0 ]; then
                        mv "$temp_dest" "$destination"
                        remove_inprogress_dir "$temp_dest"
                    else
                        rm -rf "$temp_dest"
                        remove_inprogress_dir "$temp_dest"
                    fi
                else
                    log_message "ERROR" "Pull mode requires remote_replication='yes'. Exiting."
                    return 1
                fi
            fi

            if [ $rsync_exit_code -eq 0 ]; then
                log_message "INFO" "Rsync replication succeeded."
                return 0
            elif is_retryable_exit_code "$rsync_exit_code"; then
                log_message "WARN" "Rsync attempt $((attempt+1)) failed with exit code $rsync_exit_code (retryable)."
                attempt=$((attempt + 1))
                if [ "$attempt" -lt "$rsync_retries" ]; then
                    log_message "INFO" "Retrying in $backoff seconds (exponential backoff)."
                    sleep "$backoff"
                    backoff=$((backoff * 2))
                    if [ "$backoff" -gt "$max_backoff" ]; then
                        backoff=$max_backoff
                    fi
                else
                    log_message "ERROR" "Max retries reached. Rsync failed with exit code $rsync_exit_code."
                    return $rsync_exit_code
                fi
            else
                log_message "ERROR" "Rsync failed with non-retryable exit code $rsync_exit_code."
                return $rsync_exit_code
            fi
        done
    }

    run_rsync_with_retries
}

####################
# Function: delete_old_backups_time_based
# - Removes backups older than backup_retention_days
# - For incremental: runs safety checks to ensure hard links are not broken.
####################
delete_old_backups_time_based() {
    for src in "${source_directories[@]}"; do
        local base_name
        base_name=$(sanitize_basename "$src")
        local backup_dirs="${destination_directory}/${base_name}"

        if [ ! -d "$backup_dirs" ] || [ -z "$(ls -A "$backup_dirs")" ]; then
            log_message "INFO" "No backups found for time-based retention in $backup_dirs."
            continue
        fi

        find "$backup_dirs" -maxdepth 1 -type d -mtime +"$backup_retention_days" | while read -r backup_dir; do
            if [ -d "$backup_dir" ]; then
                log_message "INFO" "Removing backup directory: $backup_dir"
                if [ "$rsync_type" = "incremental" ]; then
                    log_message "INFO" "Performing safety checks for incremental backup deletion."
                    if ! rsync -a --dry-run --delete "$backup_dir/" "$backup_dirs/"; then
                        log_message "ERROR" "Safety check failed for incremental backup. Not deleting: $backup_dir"
                    else
                        rm -rf "$backup_dir"
                    fi
                else
                    rm -rf "$backup_dir"
                fi
            fi
        done
    done
}

####################
# Function: delete_old_backups_count_based
# - Retains only the latest backup_retention_count directories for each source.
# - If incremental, also performs safety checks before deleting.
####################
delete_old_backups_count_based() {
    for src in "${source_directories[@]}"; do
        local base_name
        base_name=$(sanitize_basename "$src")
        local backup_path="${destination_directory}/${base_name}"

        if [ ! -d "$backup_path" ] || [ -z "$(ls -A "$backup_path")" ]; then
            log_message "INFO" "No backups found for count-based retention in $backup_path."
            continue
        fi

        mapfile -t backups < <(find "$backup_path" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' | sort -n | awk '{print $2}')
        log_message "INFO" "Found ${#backups[@]} backups for $base_name. Retention count is $backup_retention_count."

        if [ "${#backups[@]}" -gt "$backup_retention_count" ]; then
            log_message "INFO" "Deleting excess backups; keeping only the latest $backup_retention_count."
            for ((i=0; i<${#backups[@]}-"$backup_retention_count"; i++)); do
                local backup_dir="${backups[i]}"
                log_message "INFO" "Removing old backup: $backup_dir"
                if [ "$rsync_type" = "incremental" ]; then
                    log_message "INFO" "Safety checks for incremental backup deletion."
                    if ! rsync -a --dry-run --delete "$backup_dir/" "$backup_path/"; then
                        log_message "ERROR" "Safety check failed for incremental backup. Not deleting: $backup_dir"
                    else
                        rm -rf "$backup_dir"
                    fi
                else
                    rm -rf "$backup_dir"
                fi
            done
        else
            log_message "INFO" "No excess backups found for $base_name."
        fi
    done
}

####################
# Function: apply_retention_policy
# - Dispatches to the appropriate retention strategy (time, count, off).
####################
apply_retention_policy() {
    log_message "INFO" "Applying retention policy: $retention_policy"
    case "$retention_policy" in
        time)
            log_message "INFO" "Deleting backups older than $backup_retention_days days (time-based)."
            delete_old_backups_time_based
            ;;
        count)
            log_message "INFO" "Retaining only the latest $backup_retention_count backups (count-based)."
            delete_old_backups_count_based
            ;;
        off)
            log_message "INFO" "Retention policy disabled. No old backups will be deleted."
            ;;
    esac
}

####################
# Function: run_for_each_source
# - Iterates through all source_directories and runs rsync_replication on each.
####################
run_for_each_source() {
    for src in "${source_directories[@]}"; do
        log_message "INFO" "Starting replication for source directory: $src"
        rsync_replication "$src"
    done
    log_message "INFO" "Replication completed for all source directories."
}

####################
# Main Execution
####################
pre_run_checks
run_for_each_source
apply_retention_policy