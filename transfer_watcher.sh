#!/bin/bash
#
# transfer_watcher.sh — Monitor a directory for new/modified files and transfer them in batches via rsync.
#

set -euo pipefail

# --- Configuration ---
SOURCE_DIR="${SOURCE_DIR:?ERROR: SOURCE_DIR environment variable not set.}"
REMOTE_DEST="${REMOTE_DEST:?ERROR: REMOTE_DEST environment variable not set.}"

SOURCE_DIR=$(echo "$SOURCE_DIR" | sed 's/\/$//')

SSH_KEY="/root/.ssh/id_rsa_nas_backup"
SSH_PORT="222"

BWLIMIT_KB="${BWLIMIT_KB:-9375}"
# Calculate Mbit/s (125 KB/s = 1 Mbit/s) and ensure it's a whole number
BWLIMIT_MB=$(echo "scale=0; ${BWLIMIT_KB} / 125" | bc)

# Sync interval (seconds)
SYNC_INTERVAL="${SYNC_INTERVAL:-10}"

# Temporary file to hold event list
EVENTS_FILE="/tmp/transfer_watcher_events.txt"

# --- Time helper ---
CURRENT_TIME() {
    date '+%d/%m/%y %I:%M %p' | sed -E 's/(\s|\/)0/\1/g; s/^0//'
}

echo "Monitoring:          📤 $SOURCE_DIR"
echo "Destination:         📥 $REMOTE_DEST"
echo "Bandwidth limit:     🌐 ${BWLIMIT_KB} KB/s (${BWLIMIT_MB} Mbit/s)"
echo "Sync interval:       ⏰ ${SYNC_INTERVAL}s"
echo "-"
echo "$(CURRENT_TIME) | 🔌 Starting transfer watcher"

# --- Preflight checks ---
for cmd in inotifywait rsync ssh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "$(CURRENT_TIME) | ❌ ERROR: Missing required command: $cmd"
        exit 1
    fi
done

# --- Prepare SSH environment ---
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

# Extract just "user@host" from REMOTE_DEST (strip ":/path")
REMOTE_HOST="${REMOTE_DEST%%:*}"

# --- Remote connectivity check (quiet) ---
echo "$(CURRENT_TIME) | 🔑 Checking SSH connectivity..."
if ssh -p "$SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/.ssh/known_hosts \
    -o ConnectTimeout=5 \
    "$REMOTE_HOST" "exit" >/dev/null 2>&1; then
    echo "$(CURRENT_TIME) | 🔓 Remote connection OK."
else
    echo "$(CURRENT_TIME) | 🔐 WARNING: SSH connectivity test failed."
    echo "$(CURRENT_TIME) | ❗ NOTE: This may not indicate a real failure — rsync may still succeed later."
fi

echo "-"

# Ensure event file exists and is empty
> "$EVENTS_FILE"

# --- Cleanup handler ---
cleanup() {
    echo "$(CURRENT_TIME) | Shutting down watcher..."
    pkill -P $$ || true
    rm -f "$EVENTS_FILE"
    echo "$(CURRENT_TIME) | Clean exit."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# --- Start watcher in background ---
# CRITICAL FIX 1: Use '%f' format to output only the filename/relative path
inotifywait -m -r -q -e close_write -e moved_to --format '%w%f' "$SOURCE_DIR" |
# Read the output into a variable named 'absolute_path' for clarity
while read -r absolute_path; do
    
    # 1. Check if the absolute path is a regular file
    if [ -f "$absolute_path" ]; then
        
        # 2. Extract the relative path by removing the $SOURCE_DIR and the following slash.
        # This relative path (e.g., 'subdir/newfile.txt') is required for rsync --files-from.
        relative_path="${absolute_path#$SOURCE_DIR/}"
		
		# echo "$(CURRENT_TIME) | 🔍 Detected new file: $relative_path"

        # 3. Write the relative path to the events file
        echo "$relative_path" >> "$EVENTS_FILE"
    fi
done &

# --- Main sync loop ---
while true; do
    sleep "$SYNC_INTERVAL"

    # Skip if no events
    if [ ! -s "$EVENTS_FILE" ]; then
        continue
    fi

    echo "$(CURRENT_TIME) | 📂 Detected file changes. Starting batch sync..."

    # CRITICAL FIX 2: Use --files-from to only sync files in the EVENTS_FILE list.
    # NOTE: SOURCE_DIR must NOT have a trailing slash when using --files-from.
    if rsync -av --bwlimit="$BWLIMIT_KB" \
        -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
        --remove-source-files \
        --files-from="$EVENTS_FILE" \
        "$SOURCE_DIR" \
        "$REMOTE_DEST" >/dev/null 2>&1; then
        
        echo "$(CURRENT_TIME) | ✅ SUCCESS: Batch sync complete. Transferred $(wc -l < "$EVENTS_FILE") files."
		echo "-"
        
        # Clear the event file only on successful transfer
        > "$EVENTS_FILE"
    else
        echo "$(CURRENT_TIME) | ❌ ERROR: Batch sync failed. Files remain in event list for next attempt."
		echo "-"
    fi
done