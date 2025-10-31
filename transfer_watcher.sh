#!/bin/bash
#
# transfer_watcher.sh — Monitor a directory for new/modified files and transfer them in batches via rsync.
#

set -euo pipefail

# --- Configuration ---
SOURCE_DIR="${SOURCE_DIR:?ERROR: SOURCE_DIR environment variable not set.}"
REMOTE_DEST="${REMOTE_DEST:?ERROR: REMOTE_DEST environment variable not set.}"

SSH_KEY="/root/.ssh/id_rsa_nas_backup"
SSH_PORT="222"

# Bandwidth limit (in KB/s). Default: 9375 KB/s ≈ 75 Mbit/s
BWLIMIT_KB="${BWLIMIT_KB:-9375}"

# Sync interval (seconds)
SYNC_INTERVAL="${SYNC_INTERVAL:-10}"

# Temporary file to hold event list
EVENTS_FILE="/tmp/transfer_watcher_events.txt"

# --- Initialization ---
echo "------------------------------------------------------------"
echo "$(date '+%Y-%m-%d %H:%M:%S') | Starting transfer watcher"
echo "Monitoring:        $SOURCE_DIR"
echo "Destination:       $REMOTE_DEST"
echo "Bandwidth limit:   ${BWLIMIT_KB} KB/s"
echo "Sync interval:     ${SYNC_INTERVAL}s"
echo "------------------------------------------------------------"

touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

# --- Preflight checks ---
for cmd in inotifywait rsync ssh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Missing required command: $cmd"
        exit 1
    fi
done

# --- Remote check ---
echo "Checking SSH connectivity..."
if ! ssh -p "$SSH_PORT" -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new "$REMOTE_DEST" "exit" 2>/dev/null; then
    echo "WARNING: Unable to reach remote destination ($REMOTE_DEST). Transfers may fail."
else
    echo "Remote connection OK."
fi
echo "------------------------------------------------------------"

# Ensure event file exists and is empty
> "$EVENTS_FILE"

# --- Cleanup handler ---
cleanup() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | Shutting down watcher..."
    pkill -P $$ || true
    rm -f "$EVENTS_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | Clean exit."
    exit 0
}
trap cleanup SIGINT SIGTERM EXIT

# --- Start watcher in background ---
inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$SOURCE_DIR" |
while read -r file; do
    # Only record if it's a regular file
    [ -f "$file" ] && echo "$file" >> "$EVENTS_FILE"
done &

WATCHER_PID=$!
echo "Watcher PID: $WATCHER_PID"

# --- Main sync loop ---
while true; do
    sleep "$SYNC_INTERVAL"

    # If no events, skip
    if [ ! -s "$EVENTS_FILE" ]; then
        continue
    fi

    echo "$(date '+%Y-%m-%d %H:%M:%S') | Detected changes. Starting sync..."

    # Perform batched rsync of the full directory
    if rsync -av --bwlimit="$BWLIMIT_KB" \
        -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
        --remove-source-files \
        "$SOURCE_DIR"/ \
        "$REMOTE_DEST" >/dev/null 2>&1; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') | SUCCESS: Batch sync complete."
        > "$EVENTS_FILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR: Batch sync failed."
    fi
done