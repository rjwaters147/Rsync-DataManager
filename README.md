# Rsync DataManager

This script synchronizes files between a local machine and a remote server using Rsync. It supports both push (local to remote) and pull (remote to local) operations, and allows for incremental or full replication.

## Features

- Synchronizes files between local and remote machines.
- Supports incremental and full replication modes.
- Can push files from local to remote or pull files from remote to local.
- Logs replication activities.
- Automatically creates destination directories if they do not exist.
- Handles multiple source directories.

## Requirements

- Rsync installed on both the local and remote systems.
- SSH access to the remote server.

## Configuration

Edit the following settings in the script:

- **Source Directories**: The directories to be synchronized.
- **Destination Directory**: The directory where files will be replicated.
- **Rsync Mode**: Choose between `push` (local to remote) or `pull` (remote to local).
- **Rsync Type**: Choose between `incremental` (sync differences) or `mirror` (full replication).
- **Remote User and Server**: Set the SSH credentials for the remote server.
- **Log File Path**: Set the location where logs will be stored.

## Usage

1. Modify the script to match your environment (source directories, destination, mode, etc.).
2. Make the script executable.
3. Run the script to begin the replication process.

## Example Use Cases

- **Push Mode**: Backup local directories to a remote server.
- **Pull Mode**: Restore or synchronize files from a remote server to a local machine.
- **Incremental Replication**: Sync only the differences between the source and the destination to save space and bandwidth.
- **Full Replication**: Perform a complete copy of the source to the destination.

## License

This script is provided under the MIT License.
