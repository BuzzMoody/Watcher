#!/bin/bash
#
# health_check.sh — Performs checks to determine the container's operational status.
#

set -euo pipefail

EVENTS_FILE="/tmp/transfer_watcher_events.txt"
REMOTE_DEST="${REMOTE_DEST:?}"
SSH_KEY="/root/.ssh/id_rsa"
SSH_PORT="${SSH_PORT:-222}"

CURRENT_TIME() {
	date '+%d/%m/%y %I:%M %p' | sed -E 's/(\s|\/)0/\1/g; s/^0//'
}

# 1. Check if the main watcher process is running
if ! pgrep -f "transfer_watcher.sh" >/dev/null; then
	echo "$(CURRENT_TIME) | ❌ ERROR: Health check failed. Main watcher script is not running."
	exit 1
fi

# 2. Check if the inotifywait child process is running (optional, but good)
if ! pgrep -f "inotifywait" >/dev/null; then
	echo echo "$(CURRENT_TIME) | ❌ ERROR: Health check failed. inotifywait process is not running."
	exit 1
fi

# 3. Check for file backlog (optional: fails if too many files are stuck)
# MAX_BACKLOG_FILES=100
# if [ -s "$EVENTS_FILE" ] && [ "$(wc -l < "$EVENTS_FILE")" -gt "$MAX_BACKLOG_FILES" ]; then
# 	echo "Health check WARNING: File backlog exceeds $MAX_BACKLOG_FILES. Container is unhealthy."
# 	exit 1
# fi

# 4. Check SSH connectivity to the remote destination (Crucial for this service)
REMOTE_HOST="${REMOTE_DEST%%:*}"

# Use a very short timeout for a quick check
if ! ssh -p "$SSH_PORT" -i "$SSH_KEY" \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=3 \
	"$REMOTE_HOST" "exit" >/dev/null 2>&1; then
	echo "$(CURRENT_TIME) | ❌ ERROR: Health check failed. SSH connectivity to $REMOTE_HOST on port $SSH_PORT failed."
	exit 1
fi

echo "$(CURRENT_TIME) | 🟢 Health check passed: Watcher running, inotify active, and SSH connection successful."
exit 0