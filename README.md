# Rsync DataManager

This script automates the synchronization of files between a local system and a remote system using Rsync. It supports both push (local to remote) and pull (remote to local) operations, as well as incremental or full replication. The script provides robust logging, retention policies, and the ability to customize Rsync behavior with user-defined flags for maximum flexibility.

## Features

- **Flexible Replication**: Supports both local-to-remote (push) and remote-to-local (pull) file synchronization.
- **Incremental and Full Backups**: Choose between syncing only changed files (incremental) or performing a full copy of the data (mirror).
- **Customizable Rsync Flags**: Modify short and long Rsync flags to tailor the transfer to your needs.
- **Retention Policies**: Automatically manage old backups using time, count, or storage-based retention policies to prevent excessive storage usage.
- **Log Rotation**: Compresses and rotates log files to prevent uncontrolled log growth.
- **Automatic Directory Creation**: Automatically creates the destination directory if it doesn't exist.
- **Concurrency Control**: Prevents multiple script instances from running simultaneously using lock files.
- **Retry with Exponential Backoff**: Automatically retries failed Rsync operations with exponential backoff for transient network or I/O issues.

## Requirements

### Local Replication:
- Rsync installed on the local system.

### Remote Replication:
- Rsync installed on both the local and remote systems.
- Passwordless SSH access to the remote system.
    - Setup Guide: [RedHat Passwordless SSH](https://www.redhat.com/sysadmin/passwordless-ssh)

## Configuration

Edit the following settings in the script to suit your environment:

### Key Variables:
- **Source Directories**: Directories to be synchronized.
  - Example: `source_directories=("/path/to/source1" "/path/to/source2")`
- **Destination Directory**: Directory where the synchronized files will be stored.
  - Example: `destination_directory="/path/to/destination"`
- **Rsync Mode**: Define the sync direction: `push` (local to remote) or `pull` (remote to local).
  - Example: `rsync_mode="push"`
- **Rsync Type**: Define the replication type: `incremental` (sync differences) or `mirror` (full replication).
  - Example: `rsync_type="incremental"`

### Rsync Flags:
- **`rsync_short_args`**: Short options like `-a`, `-v`, `-z`. 
  - Example: `local_rsync_short_args="-aH"`
- **`rsync_long_args`**: Long options like `--delete`, `--checksum`.
  - Example: `local_rsync_long_args="--delete --numeric-ids --checksum"`

### Remote Connection:
- **Remote User**: Username for the remote system.
  - Example: `remote_user="username"`
- **Remote Server**: IP address or hostname of the remote system.
  - Example: `remote_server="192.168.1.100"`

### Retention Policies:
- **Retention Policy**: Choose from `time`, `count`, `storage`, or `off` to manage old backups automatically.
  - Example: `retention_policy="storage"`
- **Retention Settings**:
  - **Time-Based Retention**: Delete backups older than a specified number of days.
    - Example: `backup_retention_days=30`
  - **Count-Based Retention**: Keep only the last X backups.
    - Example: `backup_retention_count=7`
  - **Storage-Based Retention**: Delete old backups when storage exceeds a limit.
    - Example: `backup_max_storage="100G"`

### Logging:
- **Log File Path**: Define where logs will be stored.
  - Example: `log_file="/path/to/logfile.log"`

### Concurrency Control:
- The script creates a lock file to ensure only one instance of the script runs at a time. The lock file is automatically removed when the script finishes or is interrupted.

## Rsync Features

The script supports full customization of Rsync’s behavior:
- **`rsync_short_args`**: Short Rsync options for efficiency (e.g., `-a`, `-v`, `-z`).
- **`rsync_long_args`**: Long Rsync options for granular control (e.g., `--delete`, `--checksum`).
- **Exponential Backoff**: Automatically retries Rsync with increasing delays when network issues or transient errors occur.
- **Incremental Backups**: Uses `--link-dest` to create incremental backups, saving space and bandwidth.

## Example Use Cases

- **Push Mode Backup**: Sync local files to a remote server.
- **Pull Mode Restore**: Restore files from a remote server to a local system.
- **Incremental Backups**: Efficiently back up only the differences between source and destination.
- **Full Mirror Backup**: Create an exact replica of the source at the destination.
- **Automated Backup Retention**: Manage storage and prevent accumulation of old backups with retention policies.

## Initial Setup

1. **Create the Script File**:
    ```bash
    cd /opt/scripts/
    sudo nano rsync_replication.sh
    ```
    Paste the script contents into the file and save.

2. **Make the Script Executable**:
    ```bash
    sudo chmod +x /opt/scripts/rsync_replication.sh
    ```

3. **Run the Script**:
    ```bash
    sudo /opt/scripts/rsync_replication.sh
    ```

## Setting Up as a Cron Job

To automate the backup process, configure the script to run as a cron job.

1. Open the cron job configuration for the current user:
    ```bash
    crontab -e
    ```

2. Add an entry to run the script at the desired interval:
    ```bash
    0 0 * * * /path/to/rsync_replication.sh >> /path/to/logfile.log 2>&1
    ```
    This example runs the script every day at midnight.

## Restoring After Data Loss

Should your backups be needed for any reason restoring data is easy.
Simply just adjust the variables of the script as needed to push/pull data in the opposite direction you had originally configured it for.
Just make sure you include the timestamped directory as the source like so:

    ```bash
    source_directories=("/path/to/backup/source/2023-09-01_0000")
    ```

## Logging and Monitoring

Logs are written to the specified log file with detailed messages, including timestamps, errors, and Rsync operations. Old logs are automatically rotated and compressed to avoid excessive disk usage.

## License

This script is provided under the MIT License.
