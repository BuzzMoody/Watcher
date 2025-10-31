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

# --- Time helper ---
CURRENT_TIME() {
    # Ensures all date outputs respect the container TZ
    date '+%Y-%m-%d %H:%M:%S'
}

echo "------------------------------------------------------------"
echo "$(CURRENT_TIME) | Starting transfer watcher"
echo "Monitoring:        $SOURCE_DIR"
echo "Destination:       $REMOTE_DEST"
echo "Bandwidth limit:   ${BWLIMIT_KB} KB/s"
echo "Sync interval:     ${SYNC_INTERVAL}s"
echo "------------------------------------------------------------"

# --- Preflight checks ---
for cmd in inotifywait rsync ssh; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Missing required command: $cmd"
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
echo "------------------------------------------------------------"
echo "$(CURRENT_TIME) | Checking SSH connectivity..."
if ssh -p "$SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/root/.ssh/known_hosts \
    -o ConnectTimeout=5 \
    "$REMOTE_HOST" "exit" >/dev/null 2>&1; then
    echo "$(CURRENT_TIME) | Remote connection OK."
else
    echo "$(CURRENT_TIME) | WARNING: SSH connectivity test failed."
    echo "NOTE: This may not indicate a real failure — rsync may still succeed later."
fi
echo "------------------------------------------------------------"

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
inotifywait -m -r -e close_write -e moved_to --format '%w%f' "$SOURCE_DIR" |
while read -r file; do
    # Only record if it's a regular file
    [ -f "$file" ] && echo "$file" >> "$EVENTS_FILE"
done &

WATCHER_PID=$!
echo "$(CURRENT_TIME) | Watcher PID: $WATCHER_PID"

# --- Main sync loop ---
while true; do
    sleep "$SYNC_INTERVAL"

    # Skip if no events
    if [ ! -s "$EVENTS_FILE" ]; then
        continue
    fi

    echo "$(CURRENT_TIME) | Detected file changes. Starting batch sync..."

    if rsync -av --bwlimit="$BWLIMIT_KB" \
        -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
        --remove-source-files \
        "$SOURCE_DIR"/ \
        "$REMOTE_DEST" >/dev/null 2>&1; then
        echo "$(CURRENT_TIME) | SUCCESS: Batch sync complete."
        > "$EVENTS_FILE"
    else
        echo "$(CURRENT_TIME) | ERROR: Batch sync failed."
    fi
done
