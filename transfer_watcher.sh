#!/bin/bash
#
# transfer_watcher.sh — Monitor a directory for new/modified files and transfer them in batches via rsync.
#

set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:?ERROR: SOURCE_DIR environment variable not set.}"
REMOTE_DEST="${REMOTE_DEST:?ERROR: REMOTE_DEST environment variable not set.}"

SOURCE_DIR=$(echo "$SOURCE_DIR" | sed 's/\/$//')

SSH_KEY="/root/.ssh/id_rsa_nas_backup"
SSH_PORT="222"

BWLIMIT_KB="${BWLIMIT_KB:-9375}"
BWLIMIT_MB=$(echo "scale=0; ${BWLIMIT_KB} / 125" | bc)

SYNC_INTERVAL="${SYNC_INTERVAL:-10}"

EVENTS_FILE="/tmp/transfer_watcher_events.txt"

CURRENT_TIME() {
	date '+%d/%m/%y %I:%M %p' | sed -E 's/(\s|\/)0/\1/g; s/^0//'
}

check_unsynced_files() {
	echo "$(CURRENT_TIME) | 🔎 Checking for unsynced files..."

	before_count=$(wc -l < "$EVENTS_FILE" 2>/dev/null || echo 0)

	find "$SOURCE_DIR" -type f -print0 | while IFS= read -r -d $'\0' absolute_path; do
		relative_path="${absolute_path#$SOURCE_DIR/}"
		if ! grep -Fxq -- "$relative_path" "$EVENTS_FILE"; then
			echo "$relative_path" >> "$EVENTS_FILE"
			echo "$(CURRENT_TIME) | ➕ Added unsynced file: $relative_path"
		fi
	done

	after_count=$(wc -l < "$EVENTS_FILE" 2>/dev/null || echo 0)

	if [ "$before_count" -eq "$after_count" ]; then
		echo "$(CURRENT_TIME) | 📂 No unsynced files found."
	else
		echo "$(CURRENT_TIME) | 📦 Found $((after_count - before_count)) unsynced file(s)."
	fi
	
	echo "-"
}

echo "Monitoring:          📤 $SOURCE_DIR"
echo "Destination:         📥 $REMOTE_DEST"
echo "Bandwidth limit:     🌐 ${BWLIMIT_KB} KB/s (${BWLIMIT_MB} Mbit/s)"
echo "Sync interval:       ⏰ ${SYNC_INTERVAL}s"
echo "-"
echo "$(CURRENT_TIME) | 🟢 Starting transfer watcher"

for cmd in inotifywait rsync ssh; do
	if ! command -v "$cmd" &>/dev/null; then
		echo "$(CURRENT_TIME) | ❌ ERROR: Missing required command: $cmd"
		exit 1
	fi
done

mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts

REMOTE_HOST="${REMOTE_DEST%%:*}"

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

> "$EVENTS_FILE"

check_unsynced_files

cleanup() {
	echo "$(CURRENT_TIME) | 🛑 Shutting down watcher..."
	pkill -P $$ || true
	rm -f "$EVENTS_FILE"
	echo "$(CURRENT_TIME) | ✔️ Clean exit."
	echo "-"
	exit 0
}
trap cleanup SIGINT SIGTERM EXIT

inotifywait -m -r -q -e close_write -e moved_to --format '%w%f' "$SOURCE_DIR" |

while read -r absolute_path; do  
	if [ -f "$absolute_path" ]; then    
		relative_path="${absolute_path#$SOURCE_DIR/}"
		# echo "$(CURRENT_TIME) | 🔍 Detected new file: $relative_path"
		echo "$relative_path" >> "$EVENTS_FILE"
	fi
done &

while true; do
	sleep "$SYNC_INTERVAL"

	if [ ! -s "$EVENTS_FILE" ]; then
		continue
	fi

	echo "$(CURRENT_TIME) | 🔍 Detected file changes. Starting batch sync..."

	TMP_EVENTS_FILE="${EVENTS_FILE}.tmp"
	cp "$EVENTS_FILE" "$TMP_EVENTS_FILE"
	> "$EVENTS_FILE"

	if rsync -av --bwlimit="$BWLIMIT_KB" \
		-e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
		--remove-source-files \
		--files-from="$TMP_EVENTS_FILE" \
		"$SOURCE_DIR" \
		"$REMOTE_DEST" >/dev/null 2>&1; then 	
		
		echo "$(CURRENT_TIME) | ✔️ SUCCESS: Batch sync complete. Transferred $(wc -l < "$TMP_EVENTS_FILE") files."
		echo "-"
		
		> "$TMP_EVENTS_FILE"
	else
		cat "$TMP_EVENTS_FILE" >> "$EVENTS_FILE"
		sort -u "$EVENTS_FILE" -o "$EVENTS_FILE"
		> "$TMP_EVENTS_FILE"
		
		echo "$(CURRENT_TIME) | ❌ ERROR: Batch sync failed. Files remain in event list for next attempt."
		echo "-"
	fi
done