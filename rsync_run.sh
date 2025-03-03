#!/bin/bash
#set -x  # Uncomment for debugging (trace mode)
set -euo pipefail

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# #   rsync_run.sh: Orchestrates backups using GNU Parallel or sequential mode, based on configuration    # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

####################
# Load Configuration
# - Sourcing rsync_config.sh to access user-defined variables
#   like 'parallel', 'performance', 'subfolder_threshold', etc.
# - concurrency is not used in config; performance alone controls job count.
####################
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${script_dir}/rsync_config.sh"

####################
# Check if parallel is disabled
# If parallel="no", skip GNU Parallel and run sequentially.
####################
if [[ "$parallel" != "yes" ]]; then
    echo "Parallel is set to 'no'. Running all sources sequentially."
    "$script_dir/rsync_replication.sh"
    exit 0
fi

####################
# Decide concurrency & scheduling based on performance
# Uses CPU core count to derive final_concurrency.
####################
num_cores=$(nproc --all || echo 1)
final_concurrency=1  # default fallback

case "$performance" in
    high)
        # High performance: use all CPU cores
        final_concurrency="$num_cores"
        NICE_COMMAND=""
        ;;
    medium)
        # Medium performance: half the cores, but at least 1
        half_cores=$(( num_cores / 2 ))
        if (( half_cores < 1 )); then half_cores=1; fi
        final_concurrency="$half_cores"
        NICE_COMMAND="nice -n 10 ionice -c2 -n4"
        ;;
    low)
        # Low performance: quarter the cores, but at least 1
        quarter_cores=$(( num_cores / 4 ))
        if (( quarter_cores < 1 )); then quarter_cores=1; fi
        final_concurrency="$quarter_cores"
        NICE_COMMAND="nice -n 15 ionice -c2 -n7"
        ;;
    *)
        echo "Unknown performance profile '$performance'. Using default concurrency=1 (no niceness)."
        final_concurrency=1
        NICE_COMMAND=""
        ;;
esac

echo "parallel='yes'; performance='$performance' => concurrency=$final_concurrency"

####################
# Single environment check
# Runs rsync_replication.sh with --checks-only once to validate environment.
####################
$NICE_COMMAND "$script_dir/rsync_replication.sh" --checks-only

####################
# Build tasks for parallel processing
# Detects whether to split directories by subfolders or file chunks.
####################
declare -a parallel_tasks

for src in "${source_directories[@]}"; do
    subfolders=( $(find "$src" -maxdepth 1 -mindepth 1 -type d) )

    if [[ "${#subfolders[@]}" -gt "$subfolder_threshold" ]]; then
        # If many subfolders, queue each as a separate parallel task
        for sub in "${subfolders[@]}"; do
            parallel_tasks+=( "$sub" )
        done
    else
        # Check file count for chunking logic
        filecount=$(find "$src" -type f | wc -l)
        if (( filecount > file_chunk_threshold )); then
            # Large directory => split into filelist chunks
            find "$src" -type f > /tmp/allfiles_abs.txt
            sed "s|^$src/||" /tmp/allfiles_abs.txt > /tmp/allfiles_rel.txt
            split -n 4 /tmp/allfiles_rel.txt /tmp/filechunk_rel_

            for chunk in /tmp/filechunk_rel_*; do
                # Mark tasks as FILELIST
                parallel_tasks+=( "FILELIST:$chunk:$src" )
            done
        else
            # Single replication task if small enough
            parallel_tasks+=( "$src" )
        fi
    fi
done

export script_dir

####################
# Run parallel
# If FILELIST tasks, pass --source-filelist and --base-dir
# Otherwise, pass --source for normal replication
# All run under $NICE_COMMAND for CPU/disk management
####################
$NICE_COMMAND parallel -j"$final_concurrency" bash -c '
    t="$1"
    if [[ "$t" =~ FILELIST:(.*):(.*) ]]; then
        chunk="${BASH_REMATCH[1]}"
        source_dir="${BASH_REMATCH[2]}"
        "$script_dir/rsync_replication.sh" --skip-checks --source-filelist "$chunk" --base-dir "$source_dir"
    else
        "$script_dir/rsync_replication.sh" --skip-checks --source "$t"
    fi
' _ ::: "${parallel_tasks[@]}"

####################
# Final retention pass
# Calls rsync_replication.sh with --checks-only --retention-only
# after all tasks finish.
####################
$NICE_COMMAND "$script_dir/rsync_replication.sh" --checks-only --retention-only
