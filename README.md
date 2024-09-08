# Rsync DataManager

This script synchronizes files between a local machine and a remote server using Rsync. It supports both push (local to remote) and pull (remote to local) operations, and allows for incremental or full replication. Users can customize Rsync behavior through user-defined flags for maximum flexibility.

## Features

- Synchronizes files between local and remote machines.
- Supports incremental and full replication modes.
- Can push files from local to remote or pull files from remote to local.
- Logs replication activities.
- Automatically creates destination directories if they do not exist.
- Handles multiple source directories.
- Supports user-defined Rsync flags for greater control over the sync process.
- Validates configuration settings before execution.

## Requirements

- Rsync installed on both the local and remote systems.
- SSH access to the remote server.

## Configuration

Edit the following settings in the script:

- **Source Directories**: The directories to be synchronized.
- **Destination Directory**: The directory where files will be replicated.
- **Rsync Mode**: Choose between `push` (local to remote) or `pull` (remote to local).
- **Rsync Type**: Choose between `incremental` (sync differences) or `mirror` (full replication).
- **Rsync Short Arguments**: Customize short Rsync arguments (e.g., `-avz`). Defaults to `-avzH` for archive, verbose, compress, and preserving hard links.
- **Rsync Long Arguments**: Customize long Rsync options (e.g., `--delete`, `--checksum`). Defaults to `--delete --numeric-ids --checksum` for deleting on the destination, preserving IDs, and verifying file content.
- **Remote User and Server**: Set the SSH credentials for the remote server.
- **Log File Path**: Set the location where logs will be stored.

## Rsync Flags

You can configure Rsync flags in two variables:

- **`rsync_short_args`**: Short options like `-a`, `-v`, `-z` for archiving, verbosity, and compression.
- **`rsync_long_args`**: Long options like `--delete`, `--checksum` for removing files on the destination or verifying file contents.

Both sets of arguments are passed to Rsync during execution. The script will automatically add `--link-dest` when performing incremental backups.

## Example Use Cases

- **Push Mode**: Backup local directories to a remote server.
- **Pull Mode**: Restore or synchronize files from a remote server to a local machine.
- **Incremental Replication**: Sync only the differences between the source and the destination to save space and bandwidth.
- **Full Replication**: Perform a complete copy of the source to the destination.
- **Custom Rsync Flags**: Customize Rsync’s behavior with user-defined flags to optimize transfers for specific needs.

## Setting up as a Cron Job

 1. To automate the Rsync process, you can set up the script to run as a cron job:
1. To automate the Rsync process, you can set up the script to run as a cron job:

    Open the cron job configuration for the current user:
    
    `crontab -e`

 2. Add an entry to run the Rsync script at a specified interval. For example, to run the script every day at midnight, add:
2. Add an entry to run the Rsync script at a specified interval. For example, to run the script every day at midnight, add:
  
     `0 0 * * * /path/to/rsync_replication.sh >> /path/to/logfile.log 2>&1`

    - In this example:
        `0 0 * * *`: This is the cron schedule to run the script every day at midnight.
        `/path/to/rsync_replication.sh`: Replace with the full path to your Rsync script.
        `>> /path/to/logfile.log 2>&1`: This redirects both the standard output and error output to the log file.

    Save and exit the cron editor. The script will now run at the specified time.

 3. Cron Job Time Format
3. Cron Job Time Format

    `* * * * *`: Minute, Hour, Day of the Month, Month, Day of the Week.
    For example:
       - `0 0 * * *`: Run at midnight every day.
       - `0 3 * * 1`: Run at 3:00 AM every Monday.
       - `*/15 * * * *`: Run every 15 minutes.

## Logging

Logs are written to the specified log file with timestamps for each operation, providing a detailed record of the replication process, including success and failure messages.

## License

This script is provided under the MIT License.
