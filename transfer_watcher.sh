#!/bin/bash
#
# transfer_watcher.sh — Monitors a directory for new/modified files and transfers them via rsync.
#

# --- Configuration ---
SOURCE_DIR="${SOURCE_DIR:?ERROR: SOURCE_DIR environment variable not set.}"
REMOTE_DEST="${REMOTE_DEST:?ERROR: REMOTE_DEST environment variable not set.}"

SSH_KEY="/root/.ssh/id_rsa_nas_backup"
SSH_PORT="222"

# Bandwidth limit (in KB/s). Default: 9375 KB/s ≈ 75 Mbit/s
BWLIMIT_KB="${BWLIMIT_KB:-9375}"

echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"
echo "Monitoring: $SOURCE_DIR"
echo "Destination: $REMOTE_DEST"
echo "Bandwidth limit: ${BWLIMIT_KB} KB/s"
echo "---"

# --- Preflight checks ---
if ! command -v inotifywait &>/dev/null; then
    echo "ERROR: inotify-tools not installed. Exiting."
    exit 1
fi

if ! command -v rsync &>/dev/null; then
    echo "ERROR: rsync not installed. Exiting."
    exit 1
fi

# --- Main Watcher Loop ---
inotifywait -m -r -e close_write -e moved_to "$SOURCE_DIR" | while read -r path action file; do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Skip directory-only events
    if [ -z "$file" ]; then
        echo "$TIMESTAMP | Skipping directory action on $path ($action)"
        continue
    fi

    full_file_path="$path/$file"
    echo "$TIMESTAMP | Event detected: $action on $full_file_path"

    # --- Rsync Transfer with Bandwidth Limit ---
    if rsync -av --bwlimit="$BWLIMIT_KB" \
        -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no" \
        --remove-source-files \
        "$full_file_path" \
        "$REMOTE_DEST" >/dev/null 2>&1; then

        echo "$TIMESTAMP | SUCCESS: $file transferred and removed."
    else
        echo "$TIMESTAMP | ERROR: Failed to transfer $file."
    fi
done