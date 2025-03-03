#!/bin/bash
#set -x  # Uncomment for debugging (trace mode)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   Configuration file for Rsync to or from a remote server                                                                               # #
# #   This file is intended to be sourced by rsync_replication.sh                                                                           # #
# #   Contains user-adjustable variables for replication and retention                                                                      # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

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
destination_directory="/path/to/destination/directory" # (e.g., "/mnt/backup/rsync")

####################
# Rsync replication variables
# - rsync_type: Determines whether the sync is incremental or full.
# - rsync_mode: Defines the direction of the sync: "push" (local to remote) or "pull" (remote to local).
####################
rsync_type="incremental"  # "incremental" or "mirror"
rsync_mode="push"         # "push" or "pull"

####################
# Rsync flags (user-defined)
# - rsync_short_args: Short rsync arguments (e.g., "-a", "-v", "-z").
# - rsync_long_args: Long rsync arguments (e.g., "--delete", "--checksum").
# - Note: If rsync_type is set to incremental --link_dest will be added automatically
# - These flags will be applied based on the replication type.
####################
rsync_retries=3 # Number of times to retry on failure
local_rsync_short_args="-aHA" # Default short arguments for local replication only
local_rsync_long_args="--delete --numeric-ids --delete-excluded --delete-missing-args --checksum --partial --inplace" # Default long arguments for local replication only
remote_rsync_short_args="-aHvzA" # Default short arguments for remote replication only
remote_rsync_long_args="--delete --numeric-ids --delete-excluded --delete-missing-args --checksum --partial --compress-level=1" # Default long arguments for remote replication only

####################
# Remote replication variables
# - remote_replication: Can be "yes" for remote replication or "no" for local replication.
# - remote_user: Username for remote server.
# - remote_server: Remote server address.
####################
remote_replication="no" # Set to "yes" for remote replication, "no" for local replication
remote_user="remote_username" # Username for remote server (e.g., root)
remote_server="remote_server_address" # IP or hostname (e.g., 192.168.1.200)

####################
# Retention Policy
# - Choose the retention policy: time, count, or off.
#   - time: Deletes backups older than a specified number of days.
#   - count: Keeps only the latest X backups.
#   - off: No backups are deleted.
####################
retention_policy="count"  # "time", "count", or "off"
backup_retention_days=30  # Maximum days for time-based retention
backup_retention_count=10 # Maximum number for count-based retention

####################
# Logging
# - How log messages will be saved.
####################
use_syslog="yes" # "yes" to send logs to syslog/journald, "no" to disable logging

####################
# Logging Level
# - Supported: DEBUG, INFO, WARN, ERROR
#   DEBUG: log everything
#   INFO:  log INFO/WARN/ERROR
#   WARN:  log WARN/ERROR
#   ERROR: log only ERROR
####################
LOG_LEVEL="INFO" # "DEBUG", "INFO", "WARN", or "ERROR"

####################
# Parallelization & Performance
# - parallel: "yes" or "no"
#   If set to "yes", the script uses GNU Parallel for concurrency.
#   If set to "no", all backups run sequentially.
#
# - performance: "high", "medium", or "low"
#   Controls how many system resources are used when parallel is "yes".
#     high   => Max concurrency (e.g., one job per CPU core), minimal niceness.
#     medium => Moderate concurrency, moderate niceness (some system load reduction).
#     low    => Minimal concurrency, heavier niceness (least system impact).
####################
parallel="yes"            # "yes" for GNU Parallel, "no" for single-threaded
performance="low"         # "high", "medium", or "low"
subfolder_threshold=3     # If a directory has more top-level subfolders than this number, each subfolder  will be processed separately
file_chunk_threshold=1000 # If a directory contains more than this number of files, the script will split into multiple filelist chunks

####################
# In-Progress Tracking
# - This file will store paths to any .inprogress directories
#   so they can be cleaned up upon interruption or script exit.
####################
partial_inprogress_list_file="/tmp/rsync_inprogress.list"