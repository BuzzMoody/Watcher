#!/bin/bash

# Read directories from environment variables - NO DEFAULTS
SOURCE_DIR="$SOURCE_DIR"
REMOTE_DEST="$REMOTE_DEST"

# Check if required environment variables are set
if [ -z "$SOURCE_DIR" ] || [ -z "$REMOTE_DEST" ]; then
    echo "ERROR: SOURCE_DIR and REMOTE_DEST must be set via environment variables."
    exit 1
fi

# Other fixed variables
SSH_KEY="/root/.ssh/id_rsa_nas_backup" 
SSH_PORT="222"

echo "--- $(date '+%Y-%m-%d %H:%M:%S') ---"
echo "Starting monitoring of $SOURCE_DIR for new files..."
echo "Remote destination: $REMOTE_DEST"
echo "---"

# --- Main Watcher Loop ---
# Check if inotifywait is available
if ! command -v inotifywait &> /dev/null
then
    echo "ERROR: inotify-tools is not installed. Exiting."
    exit 1
fi

# The inotify loop
inotifywait -m -r -e close_write -e moved_to "$SOURCE_DIR" | while read path action file; do
    
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Handle the case where the file variable might be empty (e.g., from directory actions)
    if [ -z "$file" ]; then
        echo "$TIMESTAMP | Event detected: $action on $path (Directory action, skipping)."
        continue
    fi

    full_file_path="$path/$file"
    
    echo "$TIMESTAMP | Event detected: $action on $full_file_path"

    # --- Rsync Transfer ---
    # Redirect rsync output to /dev/null to keep logs clean,
    # or remove the '>/dev/null 2>&1' to see rsync's verbose output in docker logs.
    if rsync -av \
        -e "ssh -p $SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no" \
        --remove-source-files \
        "$full_file_path" \
        "$REMOTE_DEST" >/dev/null 2>&1; # Suppress rsync's verbose output
    then
        echo "$TIMESTAMP | SUCCESS: $file moved and deleted from local storage."
    else
        # Note: rsync errors will be captured by the 'if' statement's non-zero exit code, 
        # but the specific error message is harder to capture cleanly here without more script logic.
        echo "$TIMESTAMP | ERROR: Failed to transfer $file. Retrying may be necessary."
    fi

done