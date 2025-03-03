#!/bin/bash
#set -x  # Uncomment for debugging (trace mode)
set -euo pipefail  # Ensures the script exits on unhandled errors and no unset vars are used

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Script for Rsync to or from a remote server                                                                                           # #
# #   Intended to be run with rsync_config.sh for user-adjustable settings                                                                  # #
# #   Contains replication logic, logging, retries, atomic backups, and retention                                                           # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Load configuration file
# rsync_config.sh defines user-adjustable variables such as source_directories,
# destination_directory, rsync_type, rsync_mode, parallel, etc.
####################
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/rsync_config.sh"

####################
# Command-line argument variables
# These flags and parameters control script flow per invocation.
####################
SINGLE_SOURCE=""
SKIP_CHECKS="no"
CHECKS_ONLY="no"
RETENTION_ONLY="no"
SOURCE_FILELIST=""
BASE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            SINGLE_SOURCE="$2"
            shift 2
            ;;
        --source-filelist)
            SOURCE_FILELIST="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        --skip-checks)
            SKIP_CHECKS="yes"
            shift
            ;;
        --checks-only)
            CHECKS_ONLY="yes"
            shift
            ;;
        --retention-only)
            RETENTION_ONLY="yes"
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

####################
# Function: log_message
# Sends log messages at various levels (DEBUG, INFO, WARN, ERROR) to syslog.
# Respects the LOG_LEVEL set in rsync_config.sh.
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

    : "${LOG_LEVEL:=INFO}"  # Defaults to INFO if LOG_LEVEL is not set

    local message_level_num="${LEVEL_ORDER[$level]:-20}"
    local current_level_num="${LEVEL_ORDER[$LOG_LEVEL]:-20}"

    if (( message_level_num >= current_level_num )); then
        logger -t "rsync_replication" -p "$syslog_priority" "[${level}] ${message}"
    fi
}

####################
# Function: validate_path
# Checks a path for suspicious characters or patterns.
# Logs an error and exits if invalid characters are found.
####################
validate_path() {
    local path="$1"

    if printf '%s' "$path" | grep -Eq '[\"'"'"';|()&]'; then
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
# Validates environment before running:
#   1) Verifies required tools (rsync, ssh, etc.)
#   2) Checks rsync_type and rsync_mode
#   3) Ensures source/destination directories exist (depending on mode)
#   4) Confirms SSH connectivity if remote replication is enabled
#   5) Verifies chosen retention policy
####################
pre_run_checks() {

    ####################
    # Checks if required tools are installed
    ####################
    check_required_tools() {
        # Basic tools for any replication
        for tool in rsync du numfmt ssh logger flock; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                log_message "ERROR" "Required tool '$tool' is not installed. Exiting."
                exit 1
            fi
        done

        # Check for GNU Parallel
        if [[ "$parallel" == "yes" ]]; then
            if ! command -v parallel >/dev/null 2>&1; then
                log_message "ERROR" "GNU Parallel is not installed but parallel mode is enabled. Exiting."
                exit 1
            fi
        fi
    }

    ####################
    # Checks if rsync_type and rsync_mode are valid
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
    # Checks source directories
    # In push mode, source directories must exist locally.
    ####################
    check_source_directories() {
        if [ "${#source_directories[@]}" -eq 0 ]; then
            log_message "ERROR" "No source directories specified. Exiting."
            exit 1
        fi
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
    # Checks destination directory
    # In pull mode, creates the directory if it does not exist.
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
    # Checks SSH connection if remote_replication="yes"
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
    # Checks retention policy validity
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
# Ensures each source directory produces a unique backup name.
# If conflicts occur, appends the parent directory name to the base name.
####################
declare -A used_basenames
sanitize_basename() {
    local source_directory="$1"
    local base_name
    base_name=$(basename "$source_directory")

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
# Ensures adequate local free space if remote_replication="no" or if rsync_mode="pull".
####################
check_disk_space_local() {
    local source_path="$1"
    local destination_path="$2"

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
# Adds a directory path to partial_inprogress_list_file.
# Locks the file to prevent race conditions.
####################
add_inprogress_dir() {
    local dir="$1"
    {
        flock -x 200
        echo "$dir" >> "$partial_inprogress_list_file"
    } 200>>"$partial_inprogress_list_file"
}

####################
# Removes a directory path from partial_inprogress_list_file.
# Also uses flock to avoid race conditions.
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
# Cleanup on interrupt (SIGINT, SIGTERM)
# Reads partial_inprogress_list_file, removes directories, clears the file.
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

            : > "$partial_inprogress_list_file"
        } 200>>"$partial_inprogress_list_file"
    fi

    exit 1
}
trap 'cleanup_function' INT TERM

####################
# rsync_replication_filelist
# Copies files from a relative file list (filelist) under base_dir.
# Uses --relative to recreate the full subfolder structure in the destination.
####################
rsync_replication_filelist() {
    local filelist="$1"
    local base_dir="$2"
    local rsync_exit_code=0

    local base_name
    base_name=$(basename "$base_dir")

    local backup_date
    local destination
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

    log_message "INFO" "Executing rsync with --files-from='$filelist', --relative, base_dir='$base_dir' => '$destination'"

    mkdir -p "$(dirname "$destination")"
    local temp_dest="${destination}.inprogress"
    mkdir -p "$temp_dest"
    add_inprogress_dir "$temp_dest"

    # --relative ensures subfolders are reconstructed in temp_dest
    rsync $rsync_flags --files-from="$filelist" --relative "$base_dir" "$temp_dest/"
    rsync_exit_code=$?

    if [ $rsync_exit_code -eq 0 ]; then
        mv "$temp_dest" "$destination"
        remove_inprogress_dir "$temp_dest"
        log_message "INFO" "Filelist replication succeeded for base_dir='$base_dir'."
    else
        rm -rf "$temp_dest"
        remove_inprogress_dir "$temp_dest"
        log_message "ERROR" "Filelist replication failed with exit code $rsync_exit_code."
    fi

    return $rsync_exit_code
}

####################
# rsync_replication
# Handles local or remote push/pull replication, including retries, atomic backups, and link-dest for incremental.
####################
rsync_replication() {
    local source_directory="$1"
    local rsync_exit_code=0

    local base_name
    base_name=$(sanitize_basename "$source_directory")

    local backup_date
    local destination
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
        local previous_backup
        previous_backup=$(find "${destination_directory}/${base_name}" -maxdepth 1 -type d | sort | tail -n 1)
        if [ -n "$previous_backup" ] && [ "$previous_backup" != "${destination_directory}/${base_name}" ]; then
            rsync_flags+=" --link-dest=${previous_backup}"
        fi
    else
        log_message "INFO" "No previous backups found at '${destination_directory}/${base_name}'. Skipping --link-dest."
    fi

    check_disk_space_local "$source_directory" "$(dirname "$destination")"

    log_message "INFO" "Executing rsync from '$source_directory' to '$destination' with flags: $rsync_flags"

    local retryable_exit_codes=(10 11 12 30 35 255)
    local attempt=0
    local backoff=1
    local max_backoff=60

    ####################
    # is_retryable_exit_code
    # Checks if the rsync exit code is in the retryable list
    ####################
    is_retryable_exit_code() {
        local code="$1"
        for ec in "${retryable_exit_codes[@]}"; do
            if [ "$code" -eq "$ec" ]; then
                return 0
            fi
        done
        return 1
    }

    ####################
    # run_rsync_with_retries
    # Attempts rsync up to rsync_retries times, with exponential backoff for retryable errors.
    ####################
    run_rsync_with_retries() {
        while [ "$attempt" -lt "$rsync_retries" ]; do
            log_message "INFO" "Rsync attempt $((attempt+1)) of $rsync_retries..."

            if [ "$rsync_mode" = "push" ]; then
                # Local or remote push
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
                # Pull mode
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
                    log_message "INFO" "Sleeping $backoff seconds before retry."
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
# delete_old_backups_time_based
# Removes backups older than backup_retention_days.
# For incremental backups, performs a dry-run safety check.
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
# delete_old_backups_count_based
# Retains only the latest backup_retention_count directories for each source.
# For incremental backups, runs a safety check before deletion.
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
            log_message "INFO" "Deleting excess backups; retaining only the latest $backup_retention_count."
            for ((i=0; i<${#backups[@]}-"$backup_retention_count"; i++)); do
                local backup_dir="${backups[i]}"
                log_message "INFO" "Removing old backup: $backup_dir"
                if [ "$rsync_type" = "incremental" ]; then
                    log_message "INFO" "Performing safety checks for incremental backup deletion."
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
# apply_retention_policy
# Chooses the correct retention strategy (time, count, or off).
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
            log_message "INFO" "Retention policy is off. No backups will be deleted."
            ;;
    esac
}

####################
# run_for_each_source
# Iterates through source_directories and calls rsync_replication for each.
####################
run_for_each_source() {
    for src in "${source_directories[@]}"; do
        log_message "INFO" "Starting replication for source directory: $src"
        rsync_replication "$src"
    done
    log_message "INFO" "Replication completed for all source directories."
}

####################
# Main Execution Flow
# Checks arguments (CHECKS_ONLY, RETENTION_ONLY, etc.) and runs the appropriate functions.
####################
if [[ "$CHECKS_ONLY" == "yes" ]]; then
    pre_run_checks
    exit 0
fi

if [[ "$SKIP_CHECKS" != "yes" ]]; then
    pre_run_checks
fi

if [[ "$RETENTION_ONLY" == "yes" ]]; then
    apply_retention_policy
    exit 0
fi

if [[ -n "$SOURCE_FILELIST" && -n "$BASE_DIR" ]]; then
    rsync_replication_filelist "$SOURCE_FILELIST" "$BASE_DIR"
    apply_retention_policy
    exit 0
fi

if [[ -n "$SINGLE_SOURCE" ]]; then
    rsync_replication "$SINGLE_SOURCE"
    apply_retention_policy
    exit 0
else
    run_for_each_source
    apply_retention_policy
    exit 0
fi